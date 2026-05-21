module OneBot.Action
  ( Action (..),
    Envelope (..),
    Response (..),
    encodeAction,
    parseResponse,
  )
where

import Data.Aeson
import Data.Aeson.Types (Parser)
import Data.Text (Text)
import OneBot.Segment (Segment)
import OneBot.Types (GroupId)

-- | Subset of OneBot 11 actions we issue in the MVP.
data Action
  = SendGroupMsg !GroupId ![Segment]
  deriving stock (Show)

actionName :: Action -> Text
actionName = \case
  SendGroupMsg {} -> "send_group_msg"

actionParams :: Action -> Value
actionParams = \case
  SendGroupMsg gid segs ->
    object
      [ "group_id" .= gid,
        "message" .= segs
      ]

data Envelope = Envelope
  { action :: !Action,
    echo :: !Text
  }
  deriving stock (Show)

encodeAction :: Envelope -> Value
encodeAction env =
  object
    [ "action" .= actionName env.action,
      "params" .= actionParams env.action,
      "echo" .= env.echo
    ]

-- | OneBot 11 action response. We treat anything with @retcode@ and @echo@ as
-- a response; 'payload' is left as a raw 'Value' since each action shapes it
-- differently.
data Response = Response
  { status :: !Text,
    retcode :: !Int,
    payload :: !Value,
    echo :: !Text
  }
  deriving stock (Show)

instance FromJSON Response where
  parseJSON = withObject "Response" $ \o ->
    Response
      <$> o .: "status"
      <*> o .: "retcode"
      <*> o .:? "data" .!= Null
      <*> o .:? "echo" .!= ""

parseResponse :: Value -> Parser Response
parseResponse = parseJSON
