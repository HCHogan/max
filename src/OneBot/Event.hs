module OneBot.Event
  ( Event (..),
    GroupMessage (..),
    Sender (..),
    parseEvent,
  )
where

import Data.Aeson
import Data.Aeson.Types (Parser, parseEither)
import Data.Text (Text)
import OneBot.Segment (Segment)
import OneBot.Types (GroupId, MessageId, UserId)

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

-- | High-level event we care about. Anything we don't decode lands in 'EvRaw'
-- with the original 'Value' so it can be logged or revisited later.
data Event
  = EvGroupMessage !GroupMessage
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
        _ -> pure (EvRaw v)
    Just "meta_event" -> do
      metaType <- o .:? "meta_event_type" :: Parser (Maybe Text)
      case metaType of
        Just "heartbeat" -> pure EvHeartbeat
        Just "lifecycle" -> do
          sub <- o .:? "sub_type" .!= "unknown"
          pure (EvLifecycle sub)
        _ -> pure (EvRaw v)
    _ -> pure (EvRaw v)
eventParser v = pure (EvRaw v)

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
