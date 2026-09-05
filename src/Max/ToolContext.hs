-- |
-- Protocol-neutral identity and capability data available to tools during one
-- agent turn.  This module intentionally knows nothing about the Agent loop:
-- tools consume the context, but do not depend on their orchestrator.
module Max.ToolContext
  ( TurnIdentity (..),
    TurnCapabilities (..),
    ToolContext,
    mkToolContext,
    mkToolContextAt,
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
    toolTurnOutputContext,
    toolClearedAt,
    toolMonitorArmingAllowed,
    toolCatalogGrants,
    toolEffectCeiling,
    toolRuntimeSnapshot,
  )
where

import Data.Map.Strict (Map)
import Data.Text (Text)
import Data.Time (UTCTime)
import Max.ConversationScope (ConversationScope, conversationScopeFor)
import Max.Platform.Types (AdvertisedCaps, CanonicalMessageId, PrincipalId)
import Max.RuntimeConfig (RuntimeSnapshot)
import Max.Turn.Types (TurnOutputContext)
import OneBot.Types (GroupId, UserId)

data TurnIdentity = TurnIdentity
  { tiGroupId :: !GroupId,
    tiCanonicalId :: !CanonicalMessageId,
    tiUserId :: !UserId,
    tiSelfId :: !UserId,
    -- | Who is asking, as a person.  Tools that record something on the
    -- user's behalf (a reminder, a memory) name them by principal, so what
    -- they store survives the account they happened to speak from.
    tiAuthorPrincipalId :: !PrincipalId,
    -- | Current !clear visibility boundary.  Read tools must not resolve
    -- durable handles across it.
    tiClearedAt :: !(Maybe UTCTime),
    -- | Host-minted provenance for visible-output tools.  Model arguments
    -- cannot choose or widen it.
    tiTurnOutputContext :: !(Maybe TurnOutputContext)
  }
  deriving stock (Show, Eq)

data TurnCapabilities = TurnCapabilities
  { tcMultimodal :: !Bool,
    tcStickers :: !Bool,
    tcSkills :: !Bool,
    tcOutput :: !AdvertisedCaps,
    -- | Host-resolved role policy for standing bot-initiated activity.
    tcMonitorArming :: !Bool,
    -- | Exact current catalog exposed to this turn. Each name maps to a
    -- stable schema/effect/authority fingerprint; an arming tool freezes the
    -- map as the monitor's arm-time ceiling.
    tcCatalogGrants :: !(Map Text Text),
    -- | A fired monitor intersects its frozen grants with this turn's current
    -- catalog. Ordinary turns carry Nothing.
    tcEffectCeiling :: !(Maybe (Map Text Text)),
    tcBackground :: !Bool
  }
  deriving stock (Show, Eq)

data ToolContext = ToolContext
  { toolIdentity :: !TurnIdentity,
    toolCapabilities :: !TurnCapabilities,
    toolConversationScope :: !ConversationScope,
    toolRuntimeSnapshot :: !(Maybe RuntimeSnapshot)
  }

-- | Mint current-turn authority from the already-authorized inbound identity.
-- Model arguments never participate in this construction.
mkToolContext :: TurnIdentity -> TurnCapabilities -> ToolContext
mkToolContext identity capabilities =
  ToolContext
    { toolIdentity = identity,
      toolCapabilities = capabilities,
      toolConversationScope = conversationScopeFor identity.tiGroupId,
      toolRuntimeSnapshot = Nothing
    }

mkToolContextAt :: RuntimeSnapshot -> TurnIdentity -> TurnCapabilities -> ToolContext
mkToolContextAt snapshot identity capabilities =
  (mkToolContext identity capabilities) {toolRuntimeSnapshot = Just snapshot}

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

toolTurnOutputContext :: ToolContext -> Maybe TurnOutputContext
toolTurnOutputContext = (.toolIdentity.tiTurnOutputContext)

toolClearedAt :: ToolContext -> Maybe UTCTime
toolClearedAt = (.toolIdentity.tiClearedAt)

toolMonitorArmingAllowed :: ToolContext -> Bool
toolMonitorArmingAllowed = (.toolCapabilities.tcMonitorArming)

toolCatalogGrants :: ToolContext -> Map Text Text
toolCatalogGrants = (.toolCapabilities.tcCatalogGrants)

toolEffectCeiling :: ToolContext -> Maybe (Map Text Text)
toolEffectCeiling = (.toolCapabilities.tcEffectCeiling)
