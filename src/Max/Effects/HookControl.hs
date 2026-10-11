{-# LANGUAGE TypeFamilies #-}

module Max.Effects.HookControl (HookControl, setHook, runHookControl) where

import Data.Aeson (Value)
import Data.Text (Text)
import Effectful
import Effectful.Dispatch.Dynamic (interpret, send)
import Effectful.PostgreSQL (WithConnection)
import Max.DB.Authority (authorizeCallWithin)
import Max.DB.Hook qualified as DB
import Max.DB.Transaction (withTransaction)
import Max.Execution.Authority (CallAuthority)
import Max.Hook.Types (HookPatch)
import Max.Platform.Types (PrincipalId (..))
import Max.Turn.Types (AgentTurnId)
import OneBot.Types (GroupId (..))

data HookControl :: Effect where
  SetHook :: HookPatch -> HookControl m (Either Text Value)

type instance DispatchOf HookControl = Dynamic

setHook :: (HookControl :> es) => HookPatch -> Eff es (Either Text Value)
setHook = send . SetHook

runHookControl :: (WithConnection :> es, IOE :> es) => Maybe CallAuthority -> Maybe AgentTurnId -> GroupId -> PrincipalId -> Bool -> Eff (HookControl : es) a -> Eff es a
runHookControl authority turn group@(GroupId gid) actor@(PrincipalId principal) administrator = interpret $ \_ -> \case
  SetHook patch
    | not administrator -> pure (Left "group_administrator_required")
    | otherwise -> case turn of
        Nothing -> pure (Left "caller_fenced")
        Just current -> withTransaction $ do
          allowed <- authorizeCallWithin authority current group actor
          if allowed then DB.setHook gid principal patch else pure (Left "caller_fenced")
