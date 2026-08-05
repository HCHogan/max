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
    toolCanonicalId,
    toolUserId,
    toolAuthorPrincipalId,
    toolSelfId,
    toolMultimodal,
    toolStickers,
    toolSkills,
    toolOutputCapabilities,
  )
where

import Max.ConversationScope (ConversationScope, conversationScopeFor)
import Max.Platform.Types (AdvertisedCaps, CanonicalMessageId, PrincipalId)
import OneBot.Types (GroupId, UserId)

data TurnIdentity = TurnIdentity
  { tiGroupId :: !GroupId,
    tiCanonicalId :: !CanonicalMessageId,
    tiUserId :: !UserId,
    tiSelfId :: !UserId,
    -- | Who is asking, as a person.  Tools that record something on the
    -- user's behalf (a reminder, a memory) name them by principal, so what
    -- they store survives the account they happened to speak from.
    tiAuthorPrincipalId :: !PrincipalId
  }
  deriving stock (Show, Eq)

data TurnCapabilities = TurnCapabilities
  { tcMultimodal :: !Bool,
    tcStickers :: !Bool,
    tcSkills :: !Bool,
    tcOutput :: !AdvertisedCaps
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

toolCanonicalId :: ToolContext -> CanonicalMessageId
toolCanonicalId = (.toolIdentity.tiCanonicalId)

toolAuthorPrincipalId :: ToolContext -> PrincipalId
toolAuthorPrincipalId = (.toolIdentity.tiAuthorPrincipalId)

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

toolOutputCapabilities :: ToolContext -> AdvertisedCaps
toolOutputCapabilities = (.toolCapabilities.tcOutput)
