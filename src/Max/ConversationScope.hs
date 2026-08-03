-- |
-- The authorization context for conversation-owned data.
--
-- Max still stores both QQ groups and private chats in the historical
-- @group_id@ column (private chats use a collision-free pseudo-group id),
-- but callers should not pass that storage key around as an untyped
-- capability. A 'ConversationScope' can only be obtained from the
-- conversation attached to the current turn (or an explicitly authorized
-- command target), and every model-facing store operation takes one.
--
-- This is deliberately small. Future multi-platform identity and the
-- optional group-to-member-DM projection can grow behind this boundary
-- without reopening bare-id reads throughout the codebase.
module Max.ConversationScope
  ( ConversationScope,
    conversationScopeFor,
    conversationStorageId,
    RecallPolicy,
    GroupToDirectRecall,
    currentConversationRecall,
    authorizeGroupToDirectRecall,
    groupToDirectRecall,
    recallConversationScope,
    recallTurnScope,
  )
where

import Data.Int (Int64)
import OneBot.Types (GroupId (..))

-- | The one conversation whose resources the current operation may access.
newtype ConversationScope = ConversationScope Int64
  deriving stock (Show, Eq, Ord)

-- | The source conversation a read may project into a turn, together with the
-- turn conversation used for privacy and audit. Constructors stay private so
-- a model-provided id can never become authority.
data RecallPolicy = RecallPolicy
  { recallTurnScope :: !ConversationScope,
    recallConversationScope :: !ConversationScope
  }
  deriving stock (Show, Eq, Ord)

-- | Proof of the only supported cross-conversation read direction. The source
-- is a group and the current turn is a direct conversation. Its constructor is
-- private, so there is no corresponding DM-to-group policy.
data GroupToDirectRecall = GroupToDirectRecall
  { gdrDirectTarget :: !ConversationScope,
    gdrGroupSource :: !ConversationScope
  }
  deriving stock (Show, Eq, Ord)

-- | Construct a scope from an already-authorized conversation identity.
conversationScopeFor :: GroupId -> ConversationScope
conversationScopeFor (GroupId gid) = ConversationScope gid

-- | Transitional access to the legacy @group_id@ storage key.
--
-- Keep this accessor in store modules. Agent/model inputs must never be
-- allowed to choose the value used to construct a 'ConversationScope'.
conversationStorageId :: ConversationScope -> Int64
conversationStorageId (ConversationScope gid) = gid

currentConversationRecall :: ConversationScope -> RecallPolicy
currentConversationRecall scope = RecallPolicy scope scope

-- | Validate an explicit host-selected group-to-DM projection. Both scopes
-- must already have been authorized by non-model code. Reversed or same-kind
-- pairs are rejected by construction.
authorizeGroupToDirectRecall :: ConversationScope -> ConversationScope -> Maybe GroupToDirectRecall
authorizeGroupToDirectRecall groupSource directTarget
  | isGroup groupSource && isDirect directTarget =
      Just (GroupToDirectRecall directTarget groupSource)
  | otherwise = Nothing
  where
    isGroup (ConversationScope raw) = raw > 0
    isDirect (ConversationScope raw) = raw < 0

-- | Read from the authorized group while retaining the direct conversation as
-- the turn/privacy target. Existing single-source stores use the source field;
-- future projections can inspect both without reversing the direction.
groupToDirectRecall :: GroupToDirectRecall -> RecallPolicy
groupToDirectRecall grant =
  RecallPolicy grant.gdrDirectTarget grant.gdrGroupSource
