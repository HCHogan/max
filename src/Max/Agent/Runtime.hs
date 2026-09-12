-- | Agent assembly. The durable interpreter pins admission and its journal
-- obligation to one transaction; the model/tool loop has no database access.
module Max.Agent.Runtime (runDurableAgent, durableExecutionAdmission) where

import Control.Monad (unless)
import Effectful
import Effectful.Concurrent.Async (Concurrent)
import Effectful.Exception (throwIO)
import Effectful.Log (Log)
import Effectful.PostgreSQL (WithConnection)
import Max.Agent.Execution
import Max.DB.AgentTurn (enrichSandboxJournalStart, finishJournalExecution, markJournalOutcomeUnknown, readSkillLoads, readWorkingContext, recordAgentTurnLlmRound, recordModelNote, startJournalExecution, writeWorkingContext)
import Max.DB.Task qualified as Task
import Max.DB.Task.FrontendInput qualified as FrontendInput
import Max.DB.Transaction (withTransaction)
import Max.Effects.Agent (Agent, AgentLimits, runAgentWith)
import Max.Effects.Blob (Blob)
import Max.Effects.LLM (LLM)
import Max.Effects.ToolControl (ToolControl)
import Max.Effects.ToolOutput (ToolOutput)
import Max.Effects.Tools (ToolCatalogError, ToolRegistry)
import Max.Execution.Types (ExecutionStep (..), StepReservation (..))
import Max.Tasks (TaskCancelled (..))
import Max.Task.WorkflowRuntime (taskWorkflowHost)
import Max.ToolContext (ToolContext)
import Max.Turn.Types (AgentTurnRef (..))

runDurableAgent ::
  (LLM :> es, Concurrent :> es, Blob :> es, WithConnection :> es, Log :> es, IOE :> es) =>
  AgentLimits ->
  (ToolContext -> Either ToolCatalogError (ToolRegistry (ToolOutput : ToolControl : es))) ->
  Eff (Agent : es) a ->
  Eff es a
runDurableAgent =
  runAgentWith
    durableExecutionAdmission
    (ExecutionJournal recordModelNote finishJournalExecution markJournalOutcomeUnknown readSkillLoads readWorkingContext saveWorking)
    (ExecutionInbox (\turn -> (<>) <$> Task.taskInbox turn.atrTurnId <*> FrontendInput.readInputs turn.atrTurnId))
    (Just taskWorkflowHost)
  where
    saveWorking turn summary tokens limit = withTransaction $ do
      allowed <- Task.authorizeTaskStep turn.atrTurnId ExecutionCheckpoint
      unless allowed (throwIO TaskCancelled)
      writeWorkingContext turn summary tokens limit

-- | Commit admission and its durable pre-effect fact together.
durableExecutionAdmission :: (WithConnection :> es, IOE :> es) => ExecutionAdmission es
durableExecutionAdmission =
  ExecutionAdmission
    { eaReserveRound = \turn -> withTransaction $ do
        allowed <- Task.authorizeTaskStep turn.atrTurnId (ExecutionWork ReserveRound)
        if allowed then recordAgentTurnLlmRound turn.atrTurnId else pure False,
      eaCheck = \turn -> Task.authorizeTaskStep turn.atrTurnId ExecutionCheckpoint,
      eaStartTool = \group turn step start -> withTransaction $ do
        allowed <- Task.authorizeTaskStep turn.atrTurnId step
        unless allowed (throwIO TaskCancelled)
        enriched <- enrichSandboxJournalStart group start
        Just <$> startJournalExecution turn enriched
    }
