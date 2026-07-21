module OneBot.Event
  ( Event (..),
    GroupMessage (..),
    PokeEvent (..),
    Sender (..),
    parseEvent,
  )
where

import Data.Aeson
import Data.Aeson.Types (Parser, parseEither)
import Data.Text (Text)
import OneBot.Segment (Segment)
import OneBot.Types (GroupId, MessageId, UserId, privateChatGroupId)

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

-- | High-level event we care about. Anything we don't decode lands in 'EvRaw'
-- with the original 'Value' so it can be logged or revisited later.
data Event
  = EvGroupMessage !GroupMessage
  | EvPoke !PokeEvent
  | EvHeartbeat
  | EvLifecycle !Text
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
        Just "group" -> EvGroupMessage <$> parseGroupMessage o
        Just "private" -> EvGroupMessage <$> parsePrivateMessage o
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
    <*> pure (maybe (privateChatGroupId uid) id mGid)
    <*> pure uid
    <*> o .: "target_id"

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
