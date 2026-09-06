{-# LANGUAGE TypeFamilies #-}

-- | A per-invocation host control channel. Only domain control runners receive
-- this capability; ordinary JSON tool results cannot populate it. The Tools
-- interpreter releases a decision only when the runner succeeds.
module Max.Effects.ToolControl (ToolControl, yieldFrontend, finishExecution, runToolControl) where

import Control.Concurrent.STM (atomically, modifyTVar', newTVarIO, readTVarIO)
import Data.Text (Text)
import Effectful
import Effectful.Dispatch.Dynamic (interpret, send)
import Max.Tool.Control

data ToolControl :: Effect where
  YieldFrontend :: Text -> ToolControl m ()
  FinishExecution :: Maybe Text -> ToolControl m ()

type instance DispatchOf ToolControl = Dynamic

yieldFrontend :: (ToolControl :> es) => Text -> Eff es ()
yieldFrontend = send . YieldFrontend

finishExecution :: (ToolControl :> es) => Maybe Text -> Eff es ()
finishExecution = send . FinishExecution

runToolControl :: (IOE :> es) => Eff (ToolControl : es) a -> Eff es (a, LoopControl)
runToolControl action = do
  state <- liftIO (newTVarIO ContinueLoop)
  let record decision = atomically $ modifyTVar' state (\current -> mergeControls [current, decision])
  result <-
    interpret
      ( \_ -> \case
          YieldFrontend reply -> liftIO (record (YieldLoop reply))
          FinishExecution reply -> liftIO (record (FinishLoop reply))
      )
      action
  control <- liftIO (readTVarIO state)
  pure (result, control)
