module OneBot.Event
  ( Event (..),
    GroupMessage (..),
    HistoricalMessage (..),
    HistoryParseFailure (..),
    HistoryParseFailureSummary (..),
    MessageNotice (..),
    NoticeKind (..),
    EmojiLike (..),
    PokeEvent (..),
    Sender (..),
    parseEvent,
    parseHistoryMessages,
    summarizeHistoryParseFailures,
    selectHistoryBefore,
  )
where

import Data.Aeson
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (Parser, parseEither, typeMismatch)
import Data.Either (partitionEithers)
import Data.Int (Int64)
import Data.List (sort, sortOn)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Ord (Down (..))
import Data.Scientific (floatingOrInteger)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime, utcTimeToPOSIXSeconds)
import OneBot.Segment (Segment)
import OneBot.Types (GroupId, MessageId (..), UserId (..), parseIntId, privateChatGroupId)

data Sender = Sender
  { userId :: !UserId,
    nickname :: !(Maybe Text),
    card :: !(Maybe Text)
  }
  deriving stock (Show)

instance FromJSON Sender where
  parseJSON = withObject "Sender" $ \o ->
    Sender
      <$> o .: "user_id"
      <*> o .:? "nickname"
      <*> o .:? "card"

data GroupMessage = GroupMessage
  { selfId :: !UserId,
    groupId :: !GroupId,
    userId :: !UserId,
    messageId :: !MessageId,
    message :: ![Segment],
    rawMessage :: !Text,
    sender :: !Sender
  }
  deriving stock (Show)

-- | One message returned by NapCat's finite history actions.  The server
-- connection supplies the account and endpoint identity because history rows
-- are not full OneBot events.  A source timestamp is mandatory: without it we
-- cannot keep a response racing the reconnect from stealing a live delivery.
data HistoricalMessage = HistoricalMessage
  { hmRaw :: !Value,
    hmMessage :: !GroupMessage,
    hmOccurredAt :: !UTCTime,
    hmMessageSeq :: !(Maybe Text)
  }
  deriving stock (Show)

-- | A deliberately content-free diagnostic for one rejected history row.
-- Only a stable reason, a numeric message-id hint, and bounded top-level field
-- names survive; user-authored values and the raw payload never reach logs.
data HistoryParseFailure = HistoryParseFailure
  { hpfReason :: !Text,
    hpfMessageId :: !(Maybe MessageId),
    hpfFields :: ![Text]
  }
  deriving stock (Eq, Show)

-- | One bounded aggregate suitable for structured logs and durable audit.
data HistoryParseFailureSummary = HistoryParseFailureSummary
  { hpfsReason :: !Text,
    hpfsCount :: !Int,
    hpfsSampleMessageId :: !(Maybe MessageId),
    hpfsSampleFields :: ![Text]
  }
  deriving stock (Eq, Show)

-- | A 戳一戳 (poke) notice.  Friend pokes ride the same pseudo group
-- id scheme as private messages.
data PokeEvent = PokeEvent
  { pkSelfId :: !UserId,
    pkGroupId :: !GroupId,
    -- | Who poked.
    pkUserId :: !UserId,
    -- | Who got poked.
    pkTargetId :: !UserId
  }
  deriving stock (Show)

data EmojiLike = EmojiLike
  { emojiId :: !Text,
    count :: !Int
  }
  deriving stock (Eq, Show)

instance FromJSON EmojiLike where
  parseJSON = withObject "EmojiLike" $ \o ->
    EmojiLike
      <$> o .: "emoji_id"
      <*> o .:? "count" .!= 0

-- | Something happened to an existing message.  Every notice names the same
-- four things — whose connection saw it, where, who did it, and to which
-- message — so those are plain fields and only the variant payload lives in
-- 'mnKind'.  Splitting it the other way (one constructor per notice with the
-- reaction payload inline) gave @mnLikes@ and @mnReactionAdded@ partial
-- selectors that throw on a recall.
data MessageNotice = MessageNotice
  { mnSelfId :: !UserId,
    mnGroupId :: !GroupId,
    mnActorId :: !UserId,
    mnTargetMessageId :: !MessageId,
    mnKind :: !NoticeKind
  }
  deriving stock (Eq, Show)

data NoticeKind
  = NoticeRecalled
  | -- | The emoji set carried by this event, and whether it was added or
    -- removed.
    NoticeReacted ![EmojiLike] !Bool
  deriving stock (Eq, Show)

-- | High-level event we care about. Anything we don't decode lands in 'EvRaw'
-- with the original 'Value' so it can be logged or revisited later.
data Event
  = -- | Published atomically with the generation-tagged client and ahead of
    -- any frame from that websocket.  The handler uses it as a reconnect
    -- barrier while the read loop remains free to receive action responses.
    EvConnectionReady !Int !UTCTime
  | EvGroupMessage !Text !Value !GroupMessage
  | EvMessageNotice !Value !MessageNotice
  | EvPoke !PokeEvent
  | EvHeartbeat
  | EvLifecycle !Text
  | -- | Incoming friend request: the @flag@ (the handle
    -- @set_friend_add_request@ wants back) and the requester's id.
    EvFriendRequest !Text !UserId
  | EvRaw !Value
  deriving stock (Show)

parseEvent :: Value -> Either String Event
parseEvent = parseEither eventParser

-- | Decode the @data.messages@ returned by @get_*_msg_history@.  Individual
-- malformed rows are diagnosed and skipped instead of discarding an otherwise
-- useful bounded page.  An invalid outer response still fails the batch.
parseHistoryMessages :: UserId -> GroupId -> Value -> Either String ([HistoricalMessage], [HistoryParseFailure])
parseHistoryMessages expectedSelf expectedGroup payload = do
  rows <- parseEither historyRows payload
  let parseRow raw = case parseEither (historyMessage expectedSelf expectedGroup) raw of
        Left err -> Left (historyParseFailure raw err)
        Right message -> Right message
      (failures, messages) = partitionEithers (parseRow <$> rows)
  pure (messages, failures)

-- | Keep only the most frequent reason categories.  A category carries the
-- first bounded sample, never a raw row or parser error string.
summarizeHistoryParseFailures :: Int -> [HistoryParseFailure] -> [HistoryParseFailureSummary]
summarizeHistoryParseFailures limit failures =
  take (max 0 limit) $
    sortOn (\summary -> (Down summary.hpfsCount, summary.hpfsReason)) $
      mapMaybe toSummary $
        Map.toList grouped
  where
    grouped = Map.fromListWith (flip (<>)) [(failure.hpfReason, [failure]) | failure <- failures]
    toSummary (reason, sample : rest) =
      Just
        HistoryParseFailureSummary
          { hpfsReason = reason,
            hpfsCount = 1 + length rest,
            hpfsSampleMessageId = sample.hpfMessageId,
            hpfsSampleFields = sample.hpfFields
          }
    toSummary (_, []) = Nothing

historyParseFailure :: Value -> String -> HistoryParseFailure
historyParseFailure raw err =
  HistoryParseFailure
    { hpfReason = classifyHistoryParseFailure err,
      hpfMessageId = historyMessageIdHint raw,
      hpfFields = historyFieldNames raw
    }

classifyHistoryParseFailure :: String -> Text
classifyHistoryParseFailure rawError
  | contains "belongs to another account" = "endpoint-account-mismatch"
  | contains "belongs to another group" = "endpoint-conversation-mismatch"
  | contains "expected history message object" = "row-not-object"
  | contains "sender" = "invalid-sender"
  | contains "self_id" = "invalid-self-id"
  | contains "group_id" = "invalid-group-id"
  | contains "user_id" = "invalid-user-id"
  | contains "message_id" = "invalid-message-id"
  | contains "message_seq" = "invalid-message-seq"
  | contains "raw_message" = "invalid-raw-message"
  | contains "message" = "invalid-message"
  | contains "time" = "invalid-time"
  | otherwise = "other-schema-mismatch"
  where
    errorText = T.pack rawError
    contains needle = needle `T.isInfixOf` errorText

historyMessageIdHint :: Value -> Maybe MessageId
historyMessageIdHint (Object row) = do
  rawId <- KM.lookup (K.fromString "message_id") row
  either (const Nothing) (Just . MessageId) (parseEither (parseIntId "history message id") rawId)
historyMessageIdHint _ = Nothing

historyFieldNames :: Value -> [Text]
historyFieldNames (Object row) =
  take 16 (sort (T.take 64 . K.toText <$> KM.keys row))
historyFieldNames _ = []

-- | Keep only rows definitely older than the reconnect second, then dedupe
-- overlapping tail/anchor pages and order them for canonical ingestion.  QQ
-- timestamps have one-second precision, so dropping the whole reconnect
-- second is the conservative choice: it may miss a boundary message, but it
-- cannot consume a post-connect message before its queued live event.
selectHistoryBefore :: UTCTime -> [HistoricalMessage] -> ([HistoricalMessage], Int)
selectHistoryBefore connectedAt messages =
  (sortOn orderKey (Map.elems unique), length messages - length before)
  where
    cutoff = posixSecondsToUTCTime (fromInteger (floor (utcTimeToPOSIXSeconds connectedAt) :: Integer))
    before = filter ((< cutoff) . (.hmOccurredAt)) messages
    unique = Map.fromList [(message.hmMessage.messageId, message) | message <- before]
    orderKey message = (message.hmOccurredAt, message.hmMessage.messageId)

historyRows :: Value -> Parser [Value]
historyRows = \case
  Object o -> o .:? "messages" .!= []
  Array values -> pure (foldr (:) [] values)
  value -> fail ("expected history data object or array, got " <> show value)

historyMessage :: UserId -> GroupId -> Value -> Parser HistoricalMessage
historyMessage expectedSelf expectedGroup raw@(Object o) = do
  -- Some NapCat versions include these fields in every row and some omit
  -- them.  When present they must agree with the endpoint being recovered.
  suppliedSelf <- o .:? "self_id"
  case suppliedSelf of
    Just actual | actual /= expectedSelf -> fail "history row belongs to another account"
    _ -> pure ()
  suppliedGroup <- o .:? "group_id"
  case suppliedGroup of
    Just actual | actual /= expectedGroup -> fail "history row belongs to another group"
    _ -> pure ()
  uid <- o .: "user_id"
  suppliedSender <- o .:? "sender"
  timestamp <- o .: "time" >>= parseIntId "history time"
  sequenceNumber <- o .:? "message_seq" >>= traverse parseSequence
  groupMessage <-
    GroupMessage expectedSelf expectedGroup uid
      <$> o .: "message_id"
      <*> o .:? "message" .!= []
      <*> o .:? "raw_message" .!= ""
      <*> pure (fromMaybe (Sender uid Nothing Nothing) suppliedSender)
  pure
    HistoricalMessage
      { hmRaw = raw,
        hmMessage = groupMessage,
        hmOccurredAt = posixSecondsToUTCTime (fromIntegral (timestamp :: Int64)),
        hmMessageSeq = sequenceNumber
      }
historyMessage _ _ value = fail ("expected history message object, got " <> show value)

parseSequence :: Value -> Parser Text
parseSequence = \case
  String sequenceNumber -> pure sequenceNumber
  Number sequenceNumber -> case floatingOrInteger sequenceNumber of
    Right (integer :: Integer) -> pure (T.pack (show integer))
    Left (_ :: Double) -> fail "message_seq: expected integer, got float"
  value -> typeMismatch "message_seq" value

eventParser :: Value -> Parser Event
eventParser v@(Object o) = do
  postType <- o .:? "post_type" :: Parser (Maybe Text)
  case postType of
    Just "message" -> do
      msgType <- o .:? "message_type" :: Parser (Maybe Text)
      case msgType of
        Just "group" -> EvGroupMessage "qq" v <$> parseGroupMessage o
        Just "private" -> EvGroupMessage "qq" v <$> parsePrivateMessage o
        _ -> pure (EvRaw v)
    Just "meta_event" -> do
      metaType <- o .:? "meta_event_type" :: Parser (Maybe Text)
      case metaType of
        Just "heartbeat" -> pure EvHeartbeat
        Just "lifecycle" -> do
          sub <- o .:? "sub_type" .!= "unknown"
          pure (EvLifecycle sub)
        _ -> pure (EvRaw v)
    Just "notice" -> do
      noticeType <- o .:? "notice_type" :: Parser (Maybe Text)
      subType <- o .:? "sub_type" :: Parser (Maybe Text)
      case (noticeType, subType) of
        (Just "notify", Just "poke") -> EvPoke <$> parsePoke o
        (Just "group_recall", _) -> EvMessageNotice v <$> parseGroupRecall o
        (Just "friend_recall", _) -> EvMessageNotice v <$> parseFriendRecall o
        (Just "group_msg_emoji_like", _) -> EvMessageNotice v <$> parseMessageReaction o
        _ -> pure (EvRaw v)
    Just "request" -> do
      reqType <- o .:? "request_type" :: Parser (Maybe Text)
      case reqType of
        Just "friend" ->
          EvFriendRequest <$> o .: "flag" <*> (UserId <$> o .: "user_id")
        _ -> pure (EvRaw v)
    _ -> pure (EvRaw v)
eventParser v = pure (EvRaw v)

-- | NapCat poke notice: @user_id@ poked @target_id@; @group_id@ is
-- absent for friend pokes, which we map to the poker's pseudo group.
parsePoke :: Object -> Parser PokeEvent
parsePoke o = do
  uid <- o .: "user_id"
  mGid <- o .:? "group_id"
  PokeEvent
    <$> o .: "self_id"
    <*> pure (fromMaybe (privateChatGroupId uid) mGid)
    <*> pure uid
    <*> o .: "target_id"

parseGroupRecall :: Object -> Parser MessageNotice
parseGroupRecall o =
  MessageNotice
    <$> o .: "self_id"
    <*> o .: "group_id"
    <*> (o .:? "operator_id" >>= maybe (o .: "user_id") pure)
    <*> o .: "message_id"
    <*> pure NoticeRecalled

parseFriendRecall :: Object -> Parser MessageNotice
parseFriendRecall o = do
  user <- o .: "user_id"
  MessageNotice
    <$> o .: "self_id"
    <*> pure (privateChatGroupId user)
    <*> pure user
    <*> o .: "message_id"
    <*> pure NoticeRecalled

parseMessageReaction :: Object -> Parser MessageNotice
parseMessageReaction o = do
  likes <- o .:? "likes" .!= []
  added <- o .:? "is_add" .!= any ((> 0) . (.count)) likes
  MessageNotice
    <$> o .: "self_id"
    <*> o .: "group_id"
    <*> (o .:? "user_id" >>= maybe (o .: "operator_id") pure)
    <*> o .: "message_id"
    <*> pure (NoticeReacted likes added)

parseGroupMessage :: Object -> Parser GroupMessage
parseGroupMessage o =
  GroupMessage
    <$> o .: "self_id"
    <*> o .: "group_id"
    <*> o .: "user_id"
    <*> o .: "message_id"
    <*> o .: "message"
    <*> o .:? "raw_message" .!= ""
    <*> o .: "sender"

-- | A private message rides the same 'GroupMessage' shape under its
-- pseudo group id (see "OneBot.Types") so the whole group pipeline
-- applies unchanged.
parsePrivateMessage :: Object -> Parser GroupMessage
parsePrivateMessage o = do
  uid <- o .: "user_id"
  GroupMessage
    <$> o .: "self_id"
    <*> pure (privateChatGroupId uid)
    <*> pure uid
    <*> o .: "message_id"
    <*> o .: "message"
    <*> o .:? "raw_message" .!= ""
    <*> o .: "sender"
