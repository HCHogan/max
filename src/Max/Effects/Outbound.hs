{-# LANGUAGE TypeFamilies #-}

-- |
-- The application boundary for a visible outbound chat message.
--
-- Sending and recording are one operation because the platform assigns the
-- message id that keys our transcript row.  Keeping that round-trip here stops
-- every caller from growing its own slightly different copy of
-- @callAction -> extractOutMid -> insertOutbound@.
--
-- The result distinguishes three states that callers must not conflate:
--
-- * 'SendFailed': the platform did not accept the message;
-- * 'SentUnrecorded': the platform accepted it, but no durable row was made;
-- * 'SentRecorded': delivery and persistence both completed.
--
-- In particular, retrying 'SentUnrecorded' would duplicate a message the user
-- has already seen.  The production interpreter logs that degraded state and
-- lets the dispatch continue, matching the existing reply-path policy.
module Max.Effects.Outbound
  ( Outbound,
    OutboundRequest (..),
    SendOutcome (..),
    runOutbound,
    runOutboundWith,
    sendRecorded,
    wasDelivered,
  )
where

import Data.Aeson (object, (.=))
import Data.Text (Text)
import Data.Text qualified as T
import Effectful
import Effectful.Dispatch.Dynamic (interpret, send)
import Effectful.Exception (SomeException)
import Effectful.Log (Log, logAttention)
import Effectful.PostgreSQL (WithConnection)
import Max.DB.Message (MessageKind, insertOutbound)
import Max.Effects.PlatformApi (PlatformApi, callAction)
import Max.Util (trySync)
import OneBot.Action (Response (..), extractOutMid, sendChatMsg)
import OneBot.Segment (Segment)
import OneBot.Types (GroupId, MessageId (..), UserId)

-- | Everything fixed before one visible message is sent.
data OutboundRequest = OutboundRequest
  { orKind :: !MessageKind,
    orGroupId :: !GroupId,
    orSelfId :: !UserId,
    -- | Override for the text reconstructed from the actual segments.  Tables
    -- use their markdown source; ordinary messages leave this as 'Nothing'.
    orRenderedText :: !(Maybe Text),
    orSegments :: ![Segment],
    -- | Platform response budget in milliseconds.  Kept on the request while
    -- the existing 15s auxiliary / 30s reply policies are migrated unchanged.
    orTimeoutMs :: !Int
  }
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

-- | Production interpreter: send through the platform router, then persist the
-- exact segments under the id returned by that platform.
runOutbound ::
  forall es a.
  (PlatformApi :> es, WithConnection :> es, Log :> es, IOE :> es) =>
  Eff (Outbound : es) a ->
  Eff es a
runOutbound = runOutboundWith deliver
  where
    deliver :: OutboundRequest -> Eff es SendOutcome
    deliver req =
      callAction (sendChatMsg req.orGroupId req.orSegments) req.orTimeoutMs >>= \case
        Left err -> failed req err
        Right (Response _ rc payload _)
          | rc /= 0 -> failed req ("retcode " <> T.pack (show rc))
          | otherwise -> case extractOutMid payload of
              Nothing -> do
                let reason = "platform response carried no message_id"
                warnUnrecorded req Nothing reason
                pure (SentUnrecorded Nothing reason)
              Just rawMid -> do
                let mid = MessageId rawMid
                trySync
                  ( insertOutbound
                      req.orKind
                      req.orGroupId
                      req.orSelfId
                      "max"
                      mid
                      req.orRenderedText
                      req.orSegments
                  )
                  >>= \case
                    Right () -> pure (SentRecorded mid)
                    Left e -> do
                      let reason = "persistence failed: " <> T.pack (show (e :: SomeException))
                      warnUnrecorded req (Just mid) reason
                      pure (SentUnrecorded (Just mid) reason)

    failed :: OutboundRequest -> Text -> Eff es SendOutcome
    failed req reason = do
      logAttention "outbound: send failed" $
        object
          [ "group_id" .= req.orGroupId,
            "kind" .= T.pack (show req.orKind),
            "error" .= reason
          ]
      pure (SendFailed reason)

    warnUnrecorded :: OutboundRequest -> Maybe MessageId -> Text -> Eff es ()
    warnUnrecorded req mMid reason =
      logAttention "outbound: delivered but not recorded" $
        object
          [ "group_id" .= req.orGroupId,
            "kind" .= T.pack (show req.orKind),
            "message_id" .= mMid,
            "error" .= reason
          ]

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
