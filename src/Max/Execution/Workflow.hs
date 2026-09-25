{-# LANGUAGE RankNTypes #-}

-- | Host policy for the guest adapter, bound by assembly to one active turn.
-- Task starts, waits and progress are ordinary tools; the host only decides
-- whether this turn may run code at all.
module Max.Execution.Workflow (WorkflowHost (..), hoistWorkflowHost) where

import Effectful (Eff)

-- | False for a leaf worker (a task started with wait, or one of its
-- descendants), which runs the ordinary agent loop without run_code.
newtype WorkflowHost es = WorkflowHost {whAllowed :: Eff es Bool}

hoistWorkflowHost :: (forall a. Eff es a -> Eff target a) -> WorkflowHost es -> WorkflowHost target
hoistWorkflowHost lower host = WorkflowHost (lower host.whAllowed)
