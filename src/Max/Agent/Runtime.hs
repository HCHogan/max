-- | Agent assembly: local admission and node events, persisted diagnostics.
module Max.Agent.Runtime (runAgentRuntime, executionAdmission, executionJournal) where

import Control.Concurrent.STM (atomically)
import Data.Aeson (object, (.=))
import Effectful
import Effectful.Concurrent.Async (Concurrent)
import Effectful.Log (Log, logAttention)
import Effectful.PostgreSQL (WithConnection)
import Max.Agent.Execution
import Max.ConversationScope (conversationScopeFor)
import Max.DB.AgentTurn (enrichSandboxJournalStart, recordJournalExecution, recordModelNote)
import Max.DB.Observation (observePublishedAfter)
import Max.Effects.Agent (Agent, AgentLimits, runAgentWith)
import Max.Effects.Blob (Blob)
import Max.Effects.LLM (LLM)
import Max.Effects.ToolControl (ToolControl)
import Max.Effects.ToolOutput (ToolOutput)
import Max.Effects.Tools (ToolCatalogError, ToolRegistry)
import Max.Execution.Types (ExecutionStep (..), StepReservation (..))
import Max.Jobs qualified as Jobs
import Max.Node.Events qualified as Events
import Max.Node.Render (renderEvents)
import Max.Tasks (setTurnObservationCursor, turnEvents, turnObservationCursor, turnRuntimeAgentTurn)
import Max.ToolContext (ToolContext, toolClearedAt, toolGroupId)
import Max.Turn.Types (AgentTurnRef (..))
import Max.Util (catchSync)

runAgentRuntime ::
  (LLM :> es, Concurrent :> es, Blob :> es, WithConnection :> es, Log :> es, IOE :> es) =>
  Jobs.Jobs ->
  AgentLimits ->
  (ToolContext -> Either ToolCatalogError (ToolRegistry (ToolOutput : ToolControl : es))) ->
  Eff (Agent : es) a ->
  Eff es a
runAgentRuntime jobs =
  runAgentWith
    (executionAdmission jobs)
    executionJournal
    ( ExecutionEvents
        ( \turn context -> do
            cursor <- liftIO (turnObservationCursor turn)
            published <- case cursor of
              Nothing -> pure []
              Just after -> do
                (through, messages) <- observePublishedAfter (conversationScopeFor (toolGroupId context)) (turnRuntimeAgentTurn turn).atrTurnId (toolClearedAt context) after
                liftIO (setTurnObservationCursor turn through)
                pure messages
            events <- liftIO . atomically $ do
              Jobs.flushJobEvents jobs (turnRuntimeAgentTurn turn).atrTurnId
              turnEvents turn >>= Events.observe
            pure (published <> renderEvents events)
        )
        (\turn -> turnEvents turn >>= (`Events.awaitInterrupt` Events.noPending))
        (\turn -> liftIO . atomically $ turnEvents turn >>= Events.tryFinish)
    )
    (Just (liftIO . Jobs.acquireGuestSlot jobs . (.atrTurnId)))

executionAdmission :: (IOE :> es) => Jobs.Jobs -> ExecutionAdmission es
executionAdmission jobs =
  ExecutionAdmission
    { eaReserveRound = \turn -> liftIO (Jobs.decideJobStep jobs turn.atrTurnId (ExecutionWork ReserveRound)),
      eaCheck = \turn -> liftIO (Jobs.authorizeJobStep jobs turn.atrTurnId ExecutionCheckpoint),
      eaAdmitTool = \turn step -> liftIO (Jobs.decideJobStep jobs turn.atrTurnId step)
    }

-- | Diagnostics are best effort; cancellation still propagates.
executionJournal :: (Blob :> es, WithConnection :> es, Log :> es, IOE :> es) => ExecutionJournal es
executionJournal =
  ExecutionJournal
    { ejRecordNote = \turn ordinal note -> diagnostic (recordModelNote turn ordinal note),
      ejPrepare = \group start -> enrichSandboxJournalStart group start `catchSync` \err -> report err >> pure start,
      ejFinish = \entry result -> diagnostic (recordJournalExecution entry result)
    }
  where
    diagnostic action = action `catchSync` report
    report err = logAttention "agent diagnostic could not be stored" (object ["error" .= show err])
