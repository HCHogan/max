-- | Bind workflow host operations to the current task authority. Polling holds
-- no database connection or transaction while the ordinary worker runs a child.
module Max.Task.WorkflowRuntime (taskWorkflowHost) where

import Control.Concurrent (threadDelay)
import Data.Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Effectful
import Effectful.Exception (finally, mask, throwIO)
import Effectful.PostgreSQL (WithConnection)
import Max.CodeMode.JavaScript (javaScriptRuntimeVersion)
import Max.DB.Task.Reporting (submitProgress)
import Max.DB.Task.Workflow
import Max.Execution.Types (JournalExecution (..))
import Max.Execution.Workflow
import Max.Task.Delegation
import Max.Tasks (TaskCancelled (..))
import Max.Tool.Bundles (SkillLoad (..))
import Max.Tool.Control (LoopControl (ContinueLoop))
import Max.Tool.Types
import Max.ToolContext
import Max.Turn.Types (AgentTurnRef (..))

taskWorkflowHost :: (WithConnection :> es, IOE :> es) => ToolContext -> AgentTurnRef -> WorkflowHost es
taskWorkflowHost context turn =
  WorkflowHost
    { whAllowed = workflowAllowed turn.atrTurnId,
      whAgent = runAgent,
      whPhase = \label -> do
        accepted <- submitProgress turn.atrTurnId label
        pure $ if accepted then committed (object ["recorded" .= True]) else rejected "workflow_phase_rejected" "phase requires a current task execution",
      whParallel = True
    }
  where
    receipts = object ["runtime" .= javaScriptRuntimeVersion, "skills" .= Map.map (.slVersion) (toolSkillLoads context)]
    runAgent raw journal = case (parseAgentRequest raw, journal) of
      (Left detail, _) -> pure (rejected "invalid_agent_request" detail)
      (_, Nothing) -> pure (rejected "agent_requires_durable_task" "agent() requires a durable root task")
      (Right request, Just entry) -> mask $ \restore -> do
        started <- beginAgentStep turn.atrTurnId (toolCatalogGrants context) receipts request entry.jeJournalId
        case started of
          Left detail -> pure (rejected (if detail == "workflow_steering_pending" then detail else "agent_admission_rejected") detail)
          Right step -> restore (await entry request step) `finally` endAgentWait turn.atrTurnId step
    await entry request step = case step.cached of
      Just report -> pure (committed (receipt step True report))
      Nothing -> do
        report <- pollAgentStep turn.atrTurnId step request.outputContract entry.jeJournalId
        case report of
          Left _ -> throwIO TaskCancelled
          Right (Just value) -> pure (committed (receipt step False value))
          Right Nothing -> do
            pending <- workflowSteeringPending turn.atrTurnId
            if pending
              then pure (committed (receipt step False (object ["interrupted" .= True, "reason" .= ("workflow_steering_pending" :: Text)])))
              else liftIO (threadDelay 250000) >> await entry request step
    receipt step reused (Object fields) = Object (KM.union fields (KM.fromList ["task" .= ("task#" <> fromStringId step.childId), "reused" .= reused, "original_execution" .= ("journal#" <> fromStringId step.originalJournal)]))
    receipt _ _ value = value
    fromStringId = T.pack . show
    committed value = ToolInvocation (ToolCommitted value) ContinueLoop
    rejected code detail = ToolInvocation (ToolRejected (ToolFault code detail RetrySafe)) ContinueLoop
