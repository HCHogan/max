module Max.Handler.Access
  ( effectiveTier,
    effectiveTierKnown,
    rosterTier,
  )
where

import Data.Maybe (fromMaybe)
import Effectful (Eff, type (:>))
import Effectful.Log (Log)
import Max.Command.Permission (PermTier (..))
import Max.Dispatch (DispatchMessage (userId))
import Max.Effects.PlatformQuery (PlatformQuery)
import Max.Env (BotEnv (..))
import Max.Roster
  ( GroupMember (mRole, mUserId),
    fetchGroupMembers,
  )
import OneBot.Types (GroupId, UserId (..), isPrivateChat)

-- | Resolve authority in the target group, with config owners taking precedence.
effectiveTier :: (PlatformQuery :> es, Log :> es) => BotEnv -> GroupId -> DispatchMessage -> Eff es PermTier
effectiveTier env targetGid gm = fromMaybe TierMember <$> effectiveTierKnown env targetGid gm

effectiveTierKnown :: (PlatformQuery :> es, Log :> es) => BotEnv -> GroupId -> DispatchMessage -> Eff es (Maybe PermTier)
effectiveTierKnown env targetGid gm
  | let UserId uid = gm.userId, uid `elem` env.beOwners = pure (Just TierOwner)
  | otherwise = actorTier targetGid gm.userId

-- | Private-chat callers administer their own session. Owner tier is config-only.
actorTier :: (PlatformQuery :> es, Log :> es) => GroupId -> UserId -> Eff es (Maybe PermTier)
actorTier gid uid
  | isPrivateChat gid = pure (Just TierGroupAdmin)
  | otherwise = rosterTier uid <$> fetchGroupMembers gid

rosterTier :: UserId -> Maybe [GroupMember] -> Maybe PermTier
rosterTier uid = fmap $ \members ->
  case [member.mRole | member <- members, member.mUserId == uid] of
    (role : _) | role `elem` ["owner", "admin"] -> TierGroupAdmin
    _ -> TierMember
