-- |
-- Protocol-neutral identity and capability data available to tools during one
-- agent turn.  This module intentionally knows nothing about the Agent loop:
-- tools consume the context, but do not depend on their orchestrator.
module Max.ToolContext
  ( TurnIdentity (..),
    TurnCapabilities (..),
    ToolContext,
    mkToolContext,
    toolCapabilities,
    toolConversationScope,
    toolGroupId,
    toolMessageId,
    toolUserId,
    toolSelfId,
    toolMultimodal,
    toolStickers,
    toolSkills,
  )
where

import Max.ConversationScope (ConversationScope, conversationScopeFor)
import OneBot.Types (GroupId, MessageId, UserId)

data TurnIdentity = TurnIdentity
  { tiGroupId :: !GroupId,
    tiMessageId :: !MessageId,
    tiUserId :: !UserId,
    tiSelfId :: !UserId
  }
  deriving stock (Show, Eq)

data TurnCapabilities = TurnCapabilities
  { tcMultimodal :: !Bool,
    tcStickers :: !Bool,
    tcSkills :: !Bool
  }
  deriving stock (Show, Eq)

data ToolContext = ToolContext
  { toolIdentity :: !TurnIdentity,
    toolCapabilities :: !TurnCapabilities,
    toolConversationScope :: !ConversationScope
  }
  deriving stock (Show, Eq)

-- | Mint current-turn authority from the already-authorized inbound identity.
-- Model arguments never participate in this construction.
mkToolContext :: TurnIdentity -> TurnCapabilities -> ToolContext
mkToolContext identity capabilities =
  ToolContext
    { toolIdentity = identity,
      toolCapabilities = capabilities,
      toolConversationScope = conversationScopeFor identity.tiGroupId
    }

toolGroupId :: ToolContext -> GroupId
toolGroupId = (.toolIdentity.tiGroupId)

toolMessageId :: ToolContext -> MessageId
toolMessageId = (.toolIdentity.tiMessageId)

toolUserId :: ToolContext -> UserId
toolUserId = (.toolIdentity.tiUserId)

toolSelfId :: ToolContext -> UserId
toolSelfId = (.toolIdentity.tiSelfId)

toolMultimodal :: ToolContext -> Bool
toolMultimodal = (.toolCapabilities.tcMultimodal)

toolStickers :: ToolContext -> Bool
toolStickers = (.toolCapabilities.tcStickers)

toolSkills :: ToolContext -> Bool
toolSkills = (.toolCapabilities.tcSkills)
