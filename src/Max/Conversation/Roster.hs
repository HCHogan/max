-- | Conversation roster facts shared by read consumers and storage adapters.
module Max.Conversation.Roster (RosterIdentity (..), ConversationRoster (..)) where

import Data.Text (Text)
import GHC.Generics (Generic)
import Max.Platform.Types (Platform, PrincipalId)

-- | One account this conversation's endpoints have an identity row for,
-- together with the person behind it.
data RosterIdentity = RosterIdentity
  { riPrincipalId :: !PrincipalId,
    riPlatform :: !Platform,
    riNativeUserId :: !Text,
    riDisplayName :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)

data ConversationRoster = ConversationRoster
  { crPlatforms :: ![Platform],
    crIdentities :: ![RosterIdentity]
  }
  deriving stock (Eq, Show, Generic)
