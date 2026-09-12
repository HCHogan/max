{-# LANGUAGE RankNTypes #-}

-- | Host capabilities available to the guest adapter. Assembly binds these to
-- one durable execution; the guest cannot choose a task, actor or generation.
module Max.Execution.Workflow (WorkflowHost (..), hoistWorkflowHost) where

import Data.Aeson (Value)
import Data.Text (Text)
import Effectful (Eff)
import Max.Execution.Types (JournalExecution)
import Max.Tool.Types (ToolInvocation)

data WorkflowHost es = WorkflowHost
  { whAllowed :: Eff es Bool,
    whAgent :: Value -> Maybe JournalExecution -> Eff es ToolInvocation,
    whPhase :: Text -> Eff es ToolInvocation,
    whParallel :: Bool
  }

hoistWorkflowHost :: (forall a. Eff es a -> Eff target a) -> WorkflowHost es -> WorkflowHost target
hoistWorkflowHost lower host = WorkflowHost (lower host.whAllowed) (\value -> lower . host.whAgent value) (lower . host.whPhase) host.whParallel
