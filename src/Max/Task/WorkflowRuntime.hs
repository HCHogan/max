-- | Code-mode policy for task turns: leaf workers cannot run code.
module Max.Task.WorkflowRuntime (taskWorkflowHost) where

import Effectful
import Max.Execution.Workflow
import Max.Jobs qualified as Jobs
import Max.Task.Types
import Max.Turn.Types (AgentTurnRef (..))

taskWorkflowHost :: (IOE :> es) => Jobs.Jobs -> AgentTurnRef -> WorkflowHost es
taskWorkflowHost jobs turn = WorkflowHost (maybe True (not . (.spec.delegated)) <$> liftIO (Jobs.jobForTurn jobs turn.atrTurnId))
