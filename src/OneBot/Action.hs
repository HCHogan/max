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

-- | Subset of OneBot 11 actions we issue.
data Action
  = SendGroupMsg !GroupId ![Segment]
  | -- | Look up a forwarded message chain by its id (the @id@ in a
    -- @forward@ segment's data). NapCat returns a list of nodes.
    GetForwardMsg !Text
  | -- | Fetch a downloadable URL for a non-image group file.  The
    -- response @data.url@ is what the file worker streams from.
    GetGroupFileUrl !GroupId !Text -- group_id, file_id
  | -- | Upload a local file to the group's "群文件" area.  @file_path@
    -- is a path *inside the NapCat container* — we stage to a shared
    -- volume on the host so NapCat can read it (see docker-compose.yml).
    UploadGroupFile !GroupId !Text !Text -- group_id, file_path, display_name
  deriving stock (Show)

actionName :: Action -> Text
actionName = \case
  SendGroupMsg {} -> "send_group_msg"
  GetForwardMsg {} -> "get_forward_msg"
  GetGroupFileUrl {} -> "get_group_file_url"
  UploadGroupFile {} -> "upload_group_file"

actionParams :: Action -> Value
actionParams = \case
  SendGroupMsg gid segs ->
    object
      [ "group_id" .= gid,
        "message" .= segs
      ]
  GetForwardMsg fid ->
    -- OneBot 11 spec says @id@; NapCat also accepts @message_id@. Sending
    -- both is cheap insurance against implementation drift.
    object
      [ "id" .= fid,
        "message_id" .= fid
      ]
  GetGroupFileUrl gid fid ->
    object
      [ "group_id" .= gid,
        "file_id" .= fid,
        -- NapCat's documented field is 'busid' = 102 (file system) for
        -- normal uploads; supplying it is harmless when the server
        -- doesn't need it.
        "busid" .= (102 :: Int)
      ]
  UploadGroupFile gid path name ->
    object
      [ "group_id" .= gid,
        "file" .= path,
        "name" .= name
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
