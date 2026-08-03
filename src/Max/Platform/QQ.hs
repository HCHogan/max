-- | OneBot/NapCat edge normalization.  QQ protocol values stop here: the
-- shared ledger receives explicit endpoint identity and platform-neutral
-- content, relations and media sources.
module Max.Platform.QQ
  ( ensureQQEndpoint,
    qqEnvelope,
    qqCapabilities,
  )
where

import Data.Aeson (Value (..))
import Data.Aeson.KeyMap qualified as KeyMap
import Control.Applicative ((<|>))
import Data.Int (Int64)
import Data.Maybe (fromMaybe)
import Data.Scientific (toBoundedInteger)
import Data.Text qualified as T
import Data.Time (UTCTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Effectful
import Effectful.PostgreSQL (WithConnection)
import Max.Platform.Store (RegisteredEndpoint (..), ensureLegacyEndpoint)
import Max.Platform.Types
import OneBot.Event (GroupMessage (..), Sender (..))
import OneBot.Segment
  ( CardInfo (..),
    FileSegInfo (..),
    ImageSegInfo (..),
    Segment (..),
    VideoSegInfo (..),
    renderPlainText,
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
      content = concatMap contentPart message.message,
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

contentPart :: Segment -> [ContentPart]
contentPart = \case
  SegText body -> [ContentText body | not (T.null body)]
  SegAt (UserId user) -> [ContentMention (NativeUserId (decimal user)) Nothing]
  SegReply _ -> []
  SegImage image ->
    [ ContentMedia
        (RemoteMedia url Nothing Nothing Nothing)
        image.isiSummary
    | url <- maybeToList image.isiUrl
    ]
      <> [ContentText (renderPlainText [SegImage image]) | image.isiUrl == Nothing]
  SegFace faceId name ->
    [ContentText (fromMaybe ("[face#" <> decimal faceId <> "]") name)]
  SegFile file ->
    case file.fsiUrl of
      Just url -> [ContentMedia (RemoteMedia url Nothing file.fsiSize Nothing) (Just file.fsiName)]
      Nothing -> [ContentText ("[file: " <> file.fsiName <> "]")]
  SegVideo video ->
    case video.vsiUrl of
      Just url -> [ContentMedia (RemoteMedia url (Just "video/*") video.vsiSize Nothing) Nothing]
      Nothing -> [ContentText "[video]"]
  SegCard card ->
    [ContentText (T.intercalate " · " (filter (not . T.null) (cardText card)))]
  SegOther segmentType _ -> [ContentUnsupported ("qq:" <> segmentType)]
  where
    maybeToList = maybe [] pure
    cardText card =
      maybeToList card.ciTag
        <> maybeToList card.ciTitle
        <> maybeToList card.ciDesc
        <> maybeToList card.ciUrl

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
