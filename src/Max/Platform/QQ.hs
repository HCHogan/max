-- | OneBot/NapCat edge normalization.  QQ protocol values stop here: the
-- shared ledger receives explicit endpoint identity and an ADR 003 ingest
-- body, relations and media sources.  Nothing degrades at this boundary —
-- faces, cards, files and videos keep their structure, and every node
-- retains the raw segment payload for a same-platform native round trip.
module Max.Platform.QQ
  ( ensureQQEndpoint,
    qqEnvelope,
    qqIngestBody,
    qqSegmentNodes,
    qqCapabilities,
  )
where

import Control.Applicative ((<|>))
import Data.Aeson (Value (..), toJSON)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Int (Int64)
import Data.Maybe (fromMaybe)
import Data.Scientific (toBoundedInteger)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Effectful
import Effectful.PostgreSQL (WithConnection)
import Max.IR
import Max.Platform.Envelope (InboundEnvelope (..))
import Max.Platform.Store (RegisteredEndpoint (..), ensureLegacyEndpoint)
import Max.Platform.Types
import OneBot.Event (GroupMessage (..), Sender (..))
import OneBot.Segment
  ( CardInfo (..),
    FileSegInfo (..),
    ImageSegInfo (..),
    Segment (..),
    VideoSegInfo (..),
    isStickerImage,
  )
import OneBot.Types (GroupId (..), MessageId (..), UserId (..), isPrivateChat)

ensureQQEndpoint ::
  (WithConnection :> es, IOE :> es) =>
  GroupMessage ->
  Eff es RegisteredEndpoint
ensureQQEndpoint message =
  ensureLegacyEndpoint
    PlatformQQ
    (NativeAccountId (decimal self))
    (NativeConversationId nativeConversation)
    conversationKind
    group
    qqCapabilities
  where
    UserId self = message.selfId
    GroupId group = message.groupId
    nativeConversation
      | isPrivateChat message.groupId = "user:" <> decimal (abs group)
      | otherwise = decimal group
    conversationKind
      | isPrivateChat message.groupId = ConversationDirect
      | otherwise = ConversationGroup

qqEnvelope :: RegisteredEndpoint -> UTCTime -> Value -> GroupMessage -> InboundEnvelope
qqEnvelope endpoint received raw message =
  InboundEnvelope
    { endpointId = endpoint.endpointId,
      nativeEventId = NativeEventId (decimal messageId),
      senderNativeId = NativeUserId (decimal userId),
      senderDisplayName = message.sender.card <|> message.sender.nickname,
      occurredAt = fromMaybe received (eventTime raw),
      receivedAt = received,
      eventKind = EventMessage,
      content = qqIngestBody message.message,
      relations = concatMap relation message.message,
      sourceCursor = Nothing,
      rawPayload = Just raw
    }
  where
    MessageId messageId = message.messageId
    UserId userId = message.userId

qqCapabilities :: PlatformCapabilities
qqCapabilities =
  noCapabilities
    { canSendText = True,
      canSendMedia = True,
      canReply = True,
      canReact = True,
      maxTextBytes = Just 12000
    }

qqIngestBody :: [Segment] -> Body 'Ingest
qqIngestBody = Body . concatMap qqSegmentNodes

qqSegmentNodes :: Segment -> [Node 'Ingest]
qqSegmentNodes segment = case segment of
  SegText body -> [NText body | not (T.null body)]
  SegAt (UserId user) ->
    -- Display equals the native id here; the ingest transaction enriches
    -- it from the stored identity when one exists.
    let digits = decimal user
     in [NMention (NativeUserId digits) digits]
  SegReply _ -> []
  SegImage image ->
    [ NMedia
        (image.isiUrl >>= qqRemoteRef)
        MediaMeta
          { kind = if isStickerImage image then MSticker else MImage,
            mime = Nothing,
            sizeBytes = Nothing,
            name = Nothing,
            description = nonBlank =<< image.isiSummary,
            raw = keepRaw
          }
    ]
  SegFace faceId name ->
    [ NEmote
        Emote
          { origin = PlatformQQ,
            nativeId = decimal faceId,
            name = name,
            raw = keepRaw
          }
    ]
  SegFile file ->
    [ NMedia
        (file.fsiUrl >>= qqRemoteRef)
        MediaMeta
          { kind = MFile,
            mime = Nothing,
            sizeBytes = file.fsiSize,
            name = Just file.fsiName,
            description = Nothing,
            raw = keepRaw
          }
    ]
  SegVideo video ->
    [ NMedia
        (video.vsiUrl >>= qqRemoteRef)
        MediaMeta
          { kind = MVideo,
            mime = Nothing,
            sizeBytes = video.vsiSize,
            name = Nothing,
            description = Nothing,
            raw = keepRaw
          }
    ]
  SegCard card ->
    [ NCard
        Card
          { title = card.ciTitle,
            subtitle = card.ciDesc,
            url = card.ciUrl,
            tag = card.ciTag,
            preview = card.ciPreview >>= qqRemoteRef,
            raw = keepRaw
          }
    ]
  SegOther "forward" payload
    | Just forwardId <- forwardIdFrom payload ->
        [NForward ForwardRef {nativeId = forwardId, count = Nothing}]
  SegOther segmentType payload ->
    [ NUnsupported
        Unsupported
          { source = "qq:" <> segmentType,
            description = segmentType,
            raw = Just payload
          }
    ]
  where
    keepRaw = Just (toJSON segment)
    nonBlank value =
      let stripped = T.strip value
       in if T.null stripped then Nothing else Just stripped

forwardIdFrom :: Value -> Maybe Text
forwardIdFrom (Object payload) = case KeyMap.lookup (Key.fromText "id") payload of
  Just (String forwardId) | not (T.null forwardId) -> Just forwardId
  _ -> Nothing
forwardIdFrom _ = Nothing

qqRemoteRef :: Text -> Maybe MediaRef
qqRemoteRef value =
  mediaRemoteRef $ case T.stripPrefix "//" value of
    Just rest -> "https://" <> rest
    Nothing -> value

relation :: Segment -> [MessageRelation]
relation = \case
  SegReply (MessageId target) -> [ReplyTo (NativeEventId (decimal target))]
  _ -> []

eventTime :: Value -> Maybe UTCTime
eventTime (Object values) = do
  Number seconds <- KeyMap.lookup "time" values
  epoch <- toBoundedInteger seconds :: Maybe Int64
  pure (posixSecondsToUTCTime (fromIntegral epoch))
eventTime _ = Nothing

decimal :: (Show a) => a -> T.Text
decimal = T.pack . show
