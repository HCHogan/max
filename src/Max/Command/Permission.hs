-- |
-- Pure permission policy for the @!@-command DSL (0.3).  Resolution
-- order, high to low — first hit wins:
--
--   1. owner       — QQ id in 'AppConfig.owners'
--   2. explicit    — a @permissions@ row (grant or deny; group scope
--                    beats global — "Max.DB.Permissions")
--   3. role        — 群主\/管理员 (NapCat role), which satisfies
--                    'TierGroupAdmin'; in a private chat the sender
--                    is admin of their own session by definition
--   4. member      — everyone else
--
-- Queries (shows/lists/help) are unrestricted: only state-changing
-- verbs carry a capability.  The effectful resolver lives in
-- "Max.Handler"; this module is the pure policy table so it can be
-- unit-tested exhaustively.
module Max.Command.Permission
  ( PermTier (..),
    requiredCapability,
    tierSatisfied,
    knownCapabilities,
    adminGrantable,
  )
where

import Data.Text (Text)
import Max.Command.Types (Command (..))

-- | Ordered: 'TierMember' < 'TierGroupAdmin' < 'TierOwner'.
data PermTier = TierMember | TierGroupAdmin | TierOwner
  deriving stock (Show, Eq, Ord)

-- | Does an actor of tier @actual@ clear the bar @required@?
tierSatisfied :: PermTier -> PermTier -> Bool
tierSatisfied required actual = actual >= required

-- | The capability a command needs, with its default tier — or
-- 'Nothing' for unrestricted commands (queries, help, own-scope
-- actions).  The capability NAME is what @!grant@ hands out; the
-- tier is only the default when no explicit row exists.
requiredCapability :: Command -> Maybe (Text, PermTier)
requiredCapability = \case
  -- owner tier: cross-group or cost/identity-level switches
  ModelSet _ -> Just ("model", TierOwner)
  DebugSet _ -> Just ("debug", TierOwner)
  -- Same capability as !model: effort is a cost dial on every dispatch.
  EffortSet _ -> Just ("model", TierOwner)
  StickerSet _ -> Just ("sticker", TierOwner)
  StickerBan _ -> Just ("sticker", TierOwner)
  StickerUnban _ -> Just ("sticker", TierOwner)
  ProactiveSet _ -> Just ("proactive", TierOwner)
  KillAll -> Just ("kill-all", TierOwner)
  -- group-admin tier: group-scoped state changes
  PersonaSet _ -> Just ("persona", TierGroupAdmin)
  PersonaClear -> Just ("persona", TierGroupAdmin)
  Clear -> Just ("clear", TierGroupAdmin)
  ClearAll -> Just ("clear", TierGroupAdmin)
  Unclear -> Just ("clear", TierGroupAdmin)
  Kill _ -> Just ("kill", TierGroupAdmin)
  -- granting itself is a capability: admins can hand out their own
  -- tier's capabilities (further constrained inside execute — no
  -- --global/--deny, only 'adminGrantable' names)
  Grant {} -> Just ("grant", TierGroupAdmin)
  Revoke {} -> Just ("grant", TierGroupAdmin)
  -- everything else: queries, own-scope actions (!memory rm already
  -- ownership-checks inside execute), sandboxed !shell, pins, btw
  _ -> Nothing

-- | Every capability name @!grant@ may hand out.
knownCapabilities :: [Text]
knownCapabilities =
  ["model", "debug", "sticker", "proactive", "kill-all", "persona", "clear", "kill", "grant"]

-- | The subset a (non-owner) group admin may grant: their own tier's
-- capabilities.  Owner-tier names and cross-group flags stay
-- owner-only.
adminGrantable :: [Text]
adminGrantable = ["persona", "clear", "kill"]
