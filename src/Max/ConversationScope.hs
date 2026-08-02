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
    currentConversationRecall,
    recallConversationScope,
  )
where

import Data.Int (Int64)
import OneBot.Types (GroupId (..))

-- | The one conversation whose resources the current operation may access.
newtype ConversationScope = ConversationScope Int64
  deriving stock (Show, Eq, Ord)

-- | The conversations a read may project into the current turn.  V1 is
-- intentionally current-conversation-only.  The constructor stays private so
-- the future group-to-member-DM direction can be added here without letting a
-- model-provided id become authority.
newtype RecallPolicy = RecallPolicy ConversationScope
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
currentConversationRecall = RecallPolicy

-- | Store-internal access to the current conversation predicate.  Callers
-- construct policies only through 'currentConversationRecall'.
recallConversationScope :: RecallPolicy -> ConversationScope
recallConversationScope (RecallPolicy scope) = scope
