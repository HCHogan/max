-- | Explicit outbound backend registry.
--
-- Platform ownership is canonical database state.  This module intentionally
-- contains no synthetic-id ranges and no predicate that lets a backend claim
-- arbitrary numeric targets.
module Max.Platform
  ( PlatformBackend (..),
    ActionAddress (..),
    actionAddress,
    backendForPlatform,
  )
where

import Data.Int (Int64)
import Data.List (find)
import Data.Text (Text)
import OneBot.Action (Action (..), Response)
import OneBot.Types (GroupId (..), MessageId (..), UserId (..))

data PlatformBackend = PlatformBackend
  { pbPlatform :: !Text,
    pbName :: !Text,
    pbSend :: !(Action -> IO (Either Text ())),
    pbCall :: !(Action -> Int -> IO (Either Text Response))
  }

data ActionAddress
  = ConversationAddress !Int64
  | DirectAddress !Int64
  | MessageAddress !Int64
  | AccountAddress
  deriving stock (Eq, Show)

actionAddress :: Action -> ActionAddress
actionAddress = \case
  SendGroupMsg (GroupId group) _ -> ConversationAddress group
  SendPrivateMsg (UserId user) _ -> DirectAddress user
  GetForwardMsg _ -> AccountAddress
  GetGroupFileUrl (GroupId group) _ -> ConversationAddress group
  UploadGroupFile (GroupId group) _ _ -> ConversationAddress group
  UploadPrivateFile (UserId user) _ _ -> DirectAddress user
  GetGroupMemberList (GroupId group) -> ConversationAddress group
  GetGroupInfo (GroupId group) -> ConversationAddress group
  GetGroupMsgHistory (GroupId group) _ _ -> ConversationAddress group
  GetFriendMsgHistory (UserId user) _ _ -> DirectAddress user
  SetMsgEmojiLike (MessageId message) _ _ -> MessageAddress message
  SendPoke (GroupId group) _ -> ConversationAddress group
  SetFriendAddRequest _ _ -> AccountAddress

backendForPlatform :: Text -> [PlatformBackend] -> Maybe PlatformBackend
backendForPlatform platform = find ((== platform) . (.pbPlatform))
