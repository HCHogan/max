-- | Default command capabilities and tiers. "Max.Handler" resolves access:
-- owner > explicit grant/deny (group before global) > role > member.
-- Private-chat senders have the group-admin tier for their own session.
module Max.Command.Permission
  ( PermTier (..),
    requiredCapability,
    tierSatisfied,
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
  -- everything else: queries, own-scope actions (!memory rm already
  -- ownership-checks inside execute), sandboxed !shell, pins, btw
  _ -> Nothing
