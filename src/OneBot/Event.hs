module OneBot.Event
  ( Event (..),
    GroupMessage (..),
    MessageNotice (..),
    NoticeKind (..),
    EmojiLike (..),
    PokeEvent (..),
    Sender (..),
    parseEvent,
  )
where

import Data.Aeson
import Data.Aeson.Types (Parser, parseEither)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import OneBot.Segment (Segment)
import OneBot.Types (GroupId, MessageId, UserId (..), privateChatGroupId)

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
  = EvGroupMessage !Text !Value !GroupMessage
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
