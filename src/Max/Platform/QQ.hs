-- | OneBot/NapCat edge normalization.  QQ protocol values stop here: the
-- shared ledger receives explicit endpoint identity and an ADR 003 ingest
-- body, relations and media sources.  Nothing degrades at this boundary —
-- faces, cards, files and videos keep their structure, and every node
-- retains the raw segment payload for a same-platform native round trip.
module Max.Platform.QQ
  ( ensureQQEndpoint,
    ensureQQEndpointFor,
    qqEnvelope,
    qqNoticeEnvelopes,
    qqIngestBody,
    qqSegmentNodes,
    qqCapabilities,
  )
where

import Control.Applicative ((<|>))
import Crypto.Hash.SHA256 qualified as SHA256
import Data.Aeson (Value (..), encode, toJSON)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Base16 qualified as Base16
import Data.ByteString.Lazy qualified as LBS
import Data.Int (Int64)
import Data.Maybe (fromMaybe)
import Data.Scientific (toBoundedInteger)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Effectful
import Effectful.PostgreSQL (WithConnection)
import Max.IR
import Max.IR.Lower (OutboundCaps (..), Tier (..), textOnlyCaps)
import Max.Platform.Envelope (InboundEnvelope (..), IngestClass (LiveDelivery))
import Max.Platform.Store (RegisteredEndpoint (..), ensureLegacyEndpoint)
import Max.Platform.Types
import Max.Util (tshow)
import OneBot.Event (EmojiLike (..), GroupMessage (..), MessageNotice (..), NoticeKind (..), Sender (..))
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
  ensureQQEndpointFor message.selfId message.groupId

ensureQQEndpointFor ::
  (WithConnection :> es, IOE :> es) =>
  UserId ->
  GroupId ->
  Eff es RegisteredEndpoint
ensureQQEndpointFor selfId groupId =
  ensureLegacyEndpoint
    PlatformQQ
    (NativeAccountId (tshow self))
    (NativeConversationId nativeConversation)
    conversationKind
    group
    qqCapabilities
  where
    UserId self = selfId
    GroupId group = groupId
    nativeConversation
      | isPrivateChat groupId = "user:" <> tshow (abs group)
      | otherwise = tshow group
    conversationKind
      | isPrivateChat groupId = ConversationDirect
      | otherwise = ConversationGroup

qqEnvelope :: RegisteredEndpoint -> UTCTime -> Value -> GroupMessage -> InboundEnvelope
qqEnvelope endpoint received raw message =
  InboundEnvelope
    { endpointId = endpoint.endpointId,
      nativeEventId = NativeEventId (tshow messageId),
      senderNativeId = NativeUserId (tshow userId),
      -- QQ sends @""@ for an unset 群名片, so a plain @<|>@ lets the absent
      -- card shadow a perfectly good nickname and the ledger stores a blank
      -- name.  Downstream that blank falls all the way back to the bare
      -- principal id, which is what the roster line then shows the model.
      senderDisplayName = (nonBlank =<< message.sender.card) <|> (nonBlank =<< message.sender.nickname),
      occurredAt = fromMaybe received (eventTime raw),
      receivedAt = received,
      eventKind = EventMessage,
      ingestClass = LiveDelivery,
      content = qqIngestBody message.message,
      relations = concatMap relation message.message,
      sourceCursor = Nothing,
      rawPayload = Just raw
    }
  where
    MessageId messageId = message.messageId
    UserId userId = message.userId

qqNoticeEnvelopes :: RegisteredEndpoint -> UTCTime -> Value -> MessageNotice -> [InboundEnvelope]
qqNoticeEnvelopes endpoint received raw notice = case notice.mnKind of
  NoticeRecalled ->
    [ envelope
        (noticeId "recall")
        EventRedaction
        [Redacts (nativeMessage notice.mnTargetMessageId)]
    ]
  NoticeReacted likes added ->
    [ envelope
        (noticeId ("reaction:" <> like.emojiId <> ":" <> (if added then "add" else "remove")))
        EventReaction
        [ ReactsTo
            (nativeMessage notice.mnTargetMessageId)
            like.emojiId
            (if added then ReactionAdd else ReactionRemove)
        ]
    | like <- likes
    ]
  where
    envelope native kind relations =
      InboundEnvelope
        { endpointId = endpoint.endpointId,
          nativeEventId = NativeEventId native,
          senderNativeId = NativeUserId (userText notice.mnActorId),
          senderDisplayName = Nothing,
          occurredAt = fromMaybe received (eventTime raw),
          receivedAt = received,
          eventKind = kind,
          ingestClass = LiveDelivery,
          content = Body [],
          relations,
          sourceCursor = Nothing,
          rawPayload = Just raw
        }
    noticeId suffix =
      "notice:"
        <> TE.decodeUtf8 (Base16.encode (SHA256.hash (LBS.toStrict (encode raw))))
        <> ":"
        <> suffix
    nativeMessage (MessageId target) = NativeEventId (tshow target)
    userText (UserId actor) = tshow actor

qqCapabilities :: OutboundCaps
qqCapabilities =
  textOnlyCaps
    { mention = TierNative,
      reply = TierNative,
      emote = TierNative,
      image = TierNative,
      sticker = TierNative,
      card = TierNative,
      reaction = True,
      maxTextBytes = Just 12000,
      -- A QQ message carries several image segments, and the OneBot emitter
      -- encodes each one, so resending a multi-image message must not fold
      -- everything after the first into bare [图片] text.  Nine matches the
      -- client's own album ceiling; the delivery worker still enforces the
      -- byte budget.
      maxNativeMedia = 9
    }

qqIngestBody :: [Segment] -> Body 'Ingest
qqIngestBody = Body . concatMap qqSegmentNodes

qqSegmentNodes :: Segment -> [Node 'Ingest]
qqSegmentNodes segment = case segment of
  SegText body -> [NText body | not (T.null body)]
  SegAt (UserId user) ->
    -- Display equals the native id here; the ingest transaction enriches
    -- it from the stored identity when one exists.
    let digits = tshow user
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
            nativeId = tshow faceId,
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
  SegReply (MessageId target) -> [ReplyTo (NativeEventId (tshow target))]
  _ -> []

eventTime :: Value -> Maybe UTCTime
eventTime (Object values) = do
  Number seconds <- KeyMap.lookup "time" values
  epoch <- toBoundedInteger seconds :: Maybe Int64
  pure (posixSecondsToUTCTime (fromIntegral epoch))
eventTime _ = Nothing
