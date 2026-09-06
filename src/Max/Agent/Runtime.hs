-- | Agent assembly. The durable interpreter pins admission and its journal
-- obligation to one transaction; the model/tool loop has no database access.
module Max.Agent.Runtime (runAgent, runDurableAgent, durableExecutionAdmission) where

import Control.Monad (unless)
import Effectful
import Effectful.Concurrent.Async (Concurrent)
import Effectful.Exception (throwIO)
import Effectful.Log (Log)
import Effectful.PostgreSQL (WithConnection)
import Max.Agent.Execution
import Max.DB.AgentTurn (enrichSandboxJournalStart, finishJournalExecution, markJournalOutcomeUnknown, recordAgentTurnLlmRound, recordModelNote, startJournalExecution)
import Max.DB.Task qualified as Task
import Max.DB.Transaction (withTransaction)
import Max.Effects.Agent (Agent, AgentLimits, runAgentWith)
import Max.Effects.Blob (Blob)
import Max.Effects.LLM (LLM)
import Max.Effects.ToolControl (ToolControl)
import Max.Effects.ToolOutput (ToolOutput)
import Max.Effects.Tools (ToolCatalogError, ToolRegistry)
import Max.Execution.Types (ExecutionStep (..), StepReservation (..))
import Max.Tasks (TaskCancelled (..))
import Max.ToolContext (ToolContext)
import Max.Turn.Types (AgentTurnRef (..))

runAgent ::
  (LLM :> es, Concurrent :> es, Log :> es, IOE :> es) =>
  AgentLimits ->
  (ToolContext -> Either ToolCatalogError (ToolRegistry (ToolOutput : ToolControl : es))) ->
  Eff (Agent : es) a ->
  Eff es a
runAgent =
  runAgentWith
    (ExecutionAdmission (\_ -> pure True) (\_ -> pure True) (\_ _ _ _ -> pure Nothing))
    (ExecutionJournal (\_ _ -> pure ()) (\_ _ -> pure ()) (\_ _ -> pure ()))
    (ExecutionInbox (\_ -> pure ""))

runDurableAgent ::
  (LLM :> es, Concurrent :> es, Blob :> es, WithConnection :> es, Log :> es, IOE :> es) =>
  AgentLimits ->
  (ToolContext -> Either ToolCatalogError (ToolRegistry (ToolOutput : ToolControl : es))) ->
  Eff (Agent : es) a ->
  Eff es a
runDurableAgent =
  runAgentWith
    durableExecutionAdmission
    (ExecutionJournal recordModelNote finishJournalExecution markJournalOutcomeUnknown)
    (ExecutionInbox (Task.taskInbox . (.atrTurnId)))

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
