{-# LANGUAGE RankNTypes #-}

-- | Host capabilities available to the guest adapter. Assembly binds these to
-- one active job; the guest cannot choose a task, actor or generation.
module Max.Execution.Workflow (WorkflowHost (..), hoistWorkflowHost) where

import Data.Aeson (Value)
import Data.Text (Text)
import Effectful (Eff)
import Max.Tool.Types (ToolInvocation)

data WorkflowHost es = WorkflowHost
  { whAllowed :: Eff es Bool,
    whAgent :: Value -> Eff es ToolInvocation,
    whPhase :: Text -> Eff es ToolInvocation,
    whParallel :: Bool
  }

hoistWorkflowHost :: (forall a. Eff es a -> Eff target a) -> WorkflowHost es -> WorkflowHost target
hoistWorkflowHost lower host = WorkflowHost (lower host.whAllowed) (lower . host.whAgent) (lower . host.whPhase) host.whParallel
