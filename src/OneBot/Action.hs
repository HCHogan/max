module OneBot.Action
  ( Action (..),
    Envelope (..),
    Response (..),
    encodeAction,
    parseResponse,
    sendChatMsg,
  )
where

import Data.Aeson
import Data.Aeson.Types (Parser)
import Data.Text (Text)
import OneBot.Segment (Segment)
import OneBot.Types (GroupId, MessageId, UserId, isPrivateChat, privateChatUserId)

-- | Subset of OneBot 11 actions we issue.
data Action
  = SendGroupMsg !GroupId ![Segment]
  | SendPrivateMsg !UserId ![Segment]
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
  | -- | Private-chat counterpart of 'UploadGroupFile'.
    UploadPrivateFile !UserId !Text !Text -- user_id, file_path, display_name
  | -- | Fetch the group's member list.  Response @data@ is an array of
    -- member objects carrying @user_id@, @nickname@, @card@, @role@
    -- (owner / admin / member), @title@, among much else.  Used to
    -- validate outbound @-mention conversion against real membership
    -- and to feed the roster surfaces (see "Max.Roster").
    GetGroupMemberList !GroupId
  | -- | Fetch group metadata.  Response @data@ carries @group_name@ /
    -- @member_count@ / @max_member_count@.
    GetGroupInfo !GroupId
  | -- | React to a message with a QQ face (贴表情).  The 'Int' is the
    -- face id (face_config.json QSid); 'False' removes the bot's own
    -- reaction again.
    SetMsgEmojiLike !MessageId !Int !Bool
  deriving stock (Show)

-- | Send to the conversation behind a (possibly pseudo) group id:
-- real groups get @send_group_msg@, private pseudo-groups get
-- @send_private_msg@.  Every reply path routes through this so chat
-- kind is decided in exactly one place.
sendChatMsg :: GroupId -> [Segment] -> Action
sendChatMsg gid segs
  | isPrivateChat gid = SendPrivateMsg (privateChatUserId gid) segs
  | otherwise = SendGroupMsg gid segs

actionName :: Action -> Text
actionName = \case
  SendGroupMsg {} -> "send_group_msg"
  SendPrivateMsg {} -> "send_private_msg"
  GetForwardMsg {} -> "get_forward_msg"
  GetGroupFileUrl {} -> "get_group_file_url"
  UploadGroupFile {} -> "upload_group_file"
  UploadPrivateFile {} -> "upload_private_file"
  GetGroupMemberList {} -> "get_group_member_list"
  GetGroupInfo {} -> "get_group_info"
  SetMsgEmojiLike {} -> "set_msg_emoji_like"

actionParams :: Action -> Value
actionParams = \case
  SendGroupMsg gid segs ->
    object
      [ "group_id" .= gid,
        "message" .= segs
      ]
  SendPrivateMsg uid segs ->
    object
      [ "user_id" .= uid,
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
  UploadPrivateFile uid path name ->
    object
      [ "user_id" .= uid,
        "file" .= path,
        "name" .= name
      ]
  GetGroupMemberList gid ->
    object ["group_id" .= gid]
  GetGroupInfo gid ->
    object ["group_id" .= gid]
  SetMsgEmojiLike mid emojiId set' ->
    object
      [ "message_id" .= mid,
        "emoji_id" .= emojiId,
        "set" .= set'
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
