-- | Await process-owned children through the same task and tool authority.
module Max.Task.WorkflowRuntime (taskWorkflowHost) where

import Data.Aeson
import Data.Map.Strict qualified as Map
import Data.Maybe (isNothing)
import Effectful
import Effectful.PostgreSQL (WithConnection)
import Max.DB.Job (admitFromTurn)
import Max.Execution.Workflow
import Max.Jobs qualified as Jobs
import Max.Task.Delegation (AgentRequest (..), parseAgentRequest)
import Max.Task.Types
import Max.Tool.Control (LoopControl (ContinueLoop))
import Max.Tool.Types
import Max.ToolContext
import Max.Turn.Types (AgentTurnRef (..))

taskWorkflowHost :: (WithConnection :> es, IOE :> es) => Jobs.Jobs -> ToolContext -> AgentTurnRef -> WorkflowHost es
taskWorkflowHost jobs context turn =
  WorkflowHost
    { whAllowed = maybe True (not . (.spec.delegated)) <$> liftIO (Jobs.jobForTurn jobs turn.atrTurnId),
      whAgent = runAgent,
      whPhase = \label -> do
        accepted <- liftIO (Jobs.reportJobProgress jobs turn.atrTurnId label)
        pure $ if accepted then committed (object ["recorded" .= True]) else rejected "phase requires a current job",
      whParallel = True
    }
  where
    runAgent raw = case parseAgentRequest raw of
      Left detail -> pure (rejected detail)
      Right request -> do
        pending <- liftIO (Jobs.jobHasFeedback jobs turn.atrTurnId)
        parent <- liftIO (Jobs.jobForTurn jobs turn.atrTurnId)
        case parent of
          Just _ | pending -> pure feedbackPending
          Just job | isNothing job.spec.parent && Map.member "task_start" (toolCatalogGrants context) -> do
            let grants = taskGrants request.profile (Map.intersectionWith const (toolCatalogGrants context) job.spec.grants)
                required = case request.profile of Research -> Nothing; Browser -> Just "browser"; Sandbox -> Just "sandbox_exec"
                spec = job.spec {objective = request.objective, profile = request.profile, grants, inputs = request.inputs, parent = Just job.run, contract = request.outputContract, delegated = True, monitor = Nothing, browserProfile = Nothing}
            if maybe False (`Map.notMember` grants) required
              then pure (rejected "requested profile exceeds the parent capability ceiling")
              else
                admitFromTurn jobs turn spec >>= \case
                  Left detail -> pure (rejected detail)
                  Right child -> do
                    result <- liftIO (Jobs.waitForChildren jobs turn.atrTurnId [child.run.jobId])
                    pure $ case result of
                      Left detail -> rejected detail
                      Right FeedbackPending -> committed (object ["task" .= taskHandle child.run.jobId, "interrupted" .= True, "reason" .= ("workflow_steering_pending" :: String)])
                      Right (ChildrenFinished [finished]) -> committed (object ["task" .= taskHandle finished.run.jobId, "status" .= finished.status, "text" .= ((.text) <$> finished.result), "payload" .= (finished.result >>= (.payload))])
                      _ -> rejected "child result unavailable"
          _ -> pure (rejected "agent() requires a current root job with task_start permission")
    feedbackPending = ToolInvocation (ToolRejected (ToolFault "workflow_steering_pending" "new feedback is waiting in the parent inbox" RetrySafe)) ContinueLoop
    committed value = ToolInvocation (ToolCommitted value) ContinueLoop
    rejected detail = ToolInvocation (ToolRejected (ToolFault "agent_admission_rejected" detail RetrySafe)) ContinueLoop
