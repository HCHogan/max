{-# LANGUAGE TypeFamilies #-}

-- | A per-invocation host control channel. Only domain control runners receive
-- this capability; ordinary JSON tool results cannot populate it. The Tools
-- interpreter releases a decision only when the runner succeeds.
module Max.Effects.ToolControl (ToolControl, activateSkills, runToolControl) where

import Control.Concurrent.STM (atomically, modifyTVar', newTVarIO, readTVarIO)
import Effectful
import Effectful.Dispatch.Dynamic (interpret, send)
import Max.Tool.Bundles (SkillLoad)
import Max.Tool.Control

data ToolControl :: Effect where
  ActivateSkills :: [SkillLoad] -> ToolControl m ()

type instance DispatchOf ToolControl = Dynamic

activateSkills :: (ToolControl :> es) => [SkillLoad] -> Eff es ()
activateSkills = send . ActivateSkills

runToolControl :: (IOE :> es) => Eff (ToolControl : es) a -> Eff es (a, LoopControl)
runToolControl action = do
  state <- liftIO (newTVarIO ContinueLoop)
  let record decision = atomically $ modifyTVar' state (\current -> mergeControls [current, decision])
  result <-
    interpret
      ( \_ -> \case
          ActivateSkills loads -> liftIO (record (LoadSkills loads))
      )
      action
  control <- liftIO (readTVarIO state)
  pure (result, control)
