module Max.Platform.Roster (GroupMeta (..), GroupMember (..)) where

import Data.Text (Text)
import OneBot.Types (UserId)

data GroupMeta = GroupMeta
  { gmName :: !Text,
    gmMemberCount :: !(Maybe Int)
  }
  deriving stock (Show, Eq)

data GroupMember = GroupMember
  { mUserId :: !UserId,
    mNickname :: !(Maybe Text),
    -- | 群名片 — what the group actually sees; wins over nickname.
    mCard :: !(Maybe Text),
    -- | @owner@ / @admin@ / @member@.
    mRole :: !Text,
    -- | 专属头衔, when set.
    mTitle :: !(Maybe Text)
  }
  deriving stock (Show, Eq)
