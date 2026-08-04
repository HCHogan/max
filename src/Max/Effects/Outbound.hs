{-# LANGUAGE TypeFamilies #-}

-- |
-- The application boundary for a visible outbound chat message.
--
-- Canonical publication is the commit point.  Per-endpoint delivery is durable
-- outbox work performed afterwards, so no transport can expose a message that
-- the conversation ledger forgot.
--
-- The result distinguishes three states that callers must not conflate:
--
-- * 'SendFailed': canonical publication failed and no send is scheduled;
-- * 'SentUnrecorded': retained for test/legacy interpreters only;
-- * 'SentRecorded': canonical message and endpoint jobs are committed.
--
-- In particular, retrying 'SentUnrecorded' would duplicate a message the user
-- has already seen.  The production interpreter logs that degraded state and
-- lets the dispatch continue, matching the existing reply-path policy.
module Max.Effects.Outbound
  ( Outbound,
    OutboundRequest (..),
    OutboundDeliveryScope (..),
    SendOutcome (..),
    outboundIngestBody,
    runOutbound,
    runOutboundWith,
    sendRecorded,
    wasDelivered,
  )
where

import Data.Aeson (object, toJSON, (.=))
import Data.ByteString.Base64 qualified as B64
import Data.Maybe (fromMaybe, listToMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Effectful
import Effectful.Dispatch.Dynamic (interpret, send)
import Effectful.Exception (SomeException)
import Effectful.Log (Log, logAttention)
import Effectful.PostgreSQL (WithConnection)
import Max.DB.Message (MessageKind (..))
import Max.Effects.Blob (Blob, blobRefSha256, putBlob)
import Max.IR
import Max.Platform.QQ (qqSegmentNodes)
import Max.Platform.Store (EnqueuedOutbound (..), OutboundDraft (..), enqueueOutbound)
import Max.Platform.Types (NativeUserId (..))
import Max.Util (trySync)
import OneBot.Segment (ImageSegInfo (..), Segment (..), renderPlainText)
import OneBot.Types (GroupId (..), MessageId (..), UserId (..))

-- | Everything fixed before one visible message is sent.
data OutboundRequest = OutboundRequest
  { orKind :: !MessageKind,
    orGroupId :: !GroupId,
    orSelfId :: !UserId,
    -- | Override for the text reconstructed from the actual segments.  Tables
    -- use their markdown source; ordinary messages leave this as 'Nothing'.
    orRenderedText :: !(Maybe Text),
    orSegments :: ![Segment],
    -- | Display labels for semantic mentions.  QQ still receives native
    -- 'SegAt' values; text-only mirrors use this metadata for a readable
    -- @username fallback instead of leaking a QQ id or dropping the target.
    orMentionDisplays :: ![(UserId, Text)],
    -- | Conversation replies fan out; command/debug output can stay on the
    -- exact endpoint that supplied its durable source message.
    orDeliveryScope :: !OutboundDeliveryScope,
    -- | Platform response budget in milliseconds.  Kept on the request while
    -- the existing 15s auxiliary / 30s reply policies are migrated unchanged.
    orTimeoutMs :: !Int
  }
  deriving stock (Show, Eq)

data OutboundDeliveryScope
  = DeliverConversation
  | DeliverSourceEndpoint !MessageId
  deriving stock (Show, Eq)

-- | What became externally observable after a send attempt.
data SendOutcome
  = SendFailed !Text
  | -- | The user saw the message, but the transcript did not get a row.  The
    -- id is absent when the platform returned success without one.
    SentUnrecorded !(Maybe MessageId) !Text
  | SentRecorded !MessageId
  deriving stock (Show, Eq)

wasDelivered :: SendOutcome -> Bool
wasDelivered SendFailed {} = False
wasDelivered SentUnrecorded {} = True
wasDelivered SentRecorded {} = True

data Outbound :: Effect where
  SendRecorded :: OutboundRequest -> Outbound m SendOutcome

type instance DispatchOf Outbound = Dynamic

-- | Production interpreter: publish the canonical bot message and every
-- endpoint delivery before any transport worker can send it.  A platform
-- outage therefore leaves durable backlog instead of an unrecorded visible
-- message; 'SentRecorded' now means the canonical send intent is committed.
runOutbound ::
  forall es a.
  (Blob :> es, WithConnection :> es, Log :> es, IOE :> es) =>
  Eff (Outbound : es) a ->
  Eff es a
runOutbound = runOutboundWith deliver
  where
    deliver :: OutboundRequest -> Eff es SendOutcome
    deliver req = do
      outboundIngestBody req >>= \case
        Left err -> failed req ("canonical media import failed: " <> err)
        Right canonicalBody -> do
          let GroupId group = req.orGroupId
              rendered = fromMaybe (renderPlainText req.orSegments) req.orRenderedText
              reply = listToMaybe [message | SegReply (MessageId message) <- req.orSegments]
              draft =
                OutboundDraft
                  { legacyConversationId = group,
                    transcriptKind = renderMessageKind req.orKind,
                    sourceCompatibilityMessageId = case req.orDeliveryScope of
                      DeliverConversation -> Nothing
                      DeliverSourceEndpoint (MessageId source) -> Just source,
                    canonicalBody,
                    renderedText = rendered,
                    compatibilitySegments = toJSON req.orSegments,
                    replyToCompatibilityMessageId = reply
                  }
          trySync (enqueueOutbound draft) >>= \case
            Left e -> failed req ("canonical publish failed: " <> T.pack (show (e :: SomeException)))
            Right queued -> pure (SentRecorded (MessageId queued.compatibilityMessageId))

    failed :: OutboundRequest -> Text -> Eff es SendOutcome
    failed req reason = do
      logAttention "outbound: send failed" $
        object
          [ "group_id" .= req.orGroupId,
            "kind" .= T.pack (show req.orKind),
            "error" .= reason
          ]
      pure (SendFailed reason)

    renderMessageKind = \case
      KindChat -> "chat"
      KindCommand -> "command"
      KindDebug -> "debug"

-- | The IR body a bot message publishes.  Mentions keep their semantic
-- target (with the display label for text-tier mirrors) while the native
-- QQ segment is retained separately for QQ delivery. Inline OneBot
-- @base64://@ payloads are imported into BlobStore here, before the body can
-- enter the canonical phase; file/data schemes are refused rather than
-- smuggled into a nominal remote reference.
outboundIngestBody :: (Blob :> es) => OutboundRequest -> Eff es (Either Text (Body 'Ingest))
outboundIngestBody req = do
  nodes <- traverse toNodes req.orSegments
  pure (Body . concat <$> sequence nodes)
  where
    toNodes = \case
      SegAt user@(UserId native) ->
        let digits = T.pack (show native)
         in pure . Right $
              [ NMention
                  (NativeUserId digits)
                  (fromMaybe digits (lookup user req.orMentionDisplays))
              ]
      segment@(SegImage image) -> case qqSegmentNodes segment of
        [NMedia _ meta] -> do
          source <- case image.isiUrl of
            Nothing -> pure (Right Nothing)
            Just raw -> fmap Just <$> materializeSource raw
          pure ((\ref -> [NMedia ref meta]) <$> source)
        _ -> pure (Left "QQ image normalization did not produce one media node")
      segment -> pure (Right (qqSegmentNodes segment))

    materializeSource source
      | Just encoded <- T.stripPrefix "base64://" source =
          case B64.decode (TE.encodeUtf8 encoded) of
            Left _ -> pure (Left "invalid base64 image payload")
            Right bytes -> do
              ref <- putBlob bytes
              pure $ case mediaBlobRef (blobRefSha256 ref) of
                Just stored -> Right stored
                Nothing -> Left "BlobStore returned an invalid content address"
      | Just ref <- parseMediaRef source = pure (Right ref)
      | otherwise = pure (Left "unsupported canonical media source scheme")

-- | Install any request handler as the interpreter.  Besides keeping
-- 'runOutbound' small, this is the in-memory seam for Handler/Agent tests: a
-- fake can capture requests and choose any delivery state without PlatformApi or a
-- database.
runOutboundWith ::
  (OutboundRequest -> Eff es SendOutcome) ->
  Eff (Outbound : es) a ->
  Eff es a
runOutboundWith f = interpret $ \_ -> \case
  SendRecorded req -> f req

sendRecorded :: (Outbound :> es) => OutboundRequest -> Eff es SendOutcome
sendRecorded = send . SendRecorded
