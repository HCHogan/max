-- | Agent assembly: local admission and node events, persisted diagnostics.
module Max.Agent.Runtime (runAgentRuntime, observeAgentInputs, executionAdmission, executionJournal) where

import Control.Concurrent.STM (atomically)
import Data.Aeson (encode, object, (.=))
import Data.ByteString.Lazy qualified as LBS
import Data.Text.Encoding qualified as TE
import Effectful
import Effectful.Concurrent.Async (Concurrent)
import Effectful.Log (Log, logAttention)
import Effectful.PostgreSQL (WithConnection)
import Max.Agent.Execution
import Max.Context (estimateMessagesTokens)
import Max.Context.Read (ReadCursor (..), ReadLane (..), readLink)
import Max.ConversationScope (conversationScopeFor, conversationStorageId)
import Max.DB.AgentTurn (enrichSandboxJournalStart, recordJournalExecution, recordModelNote)
import Max.DB.Observation (PublishedCut (..), readPublishedAfter, renderPublishedWithin)
import Max.Effects.Agent (Agent, AgentLimits, runAgentWith)
import Max.Effects.Blob (Blob)
import Max.Effects.LLM (LLM)
import Max.Effects.ToolControl (ToolControl)
import Max.Effects.ToolOutput (ToolOutput)
import Max.Effects.Tools (ToolCatalogError, ToolRegistry)
import Max.Execution.Authority (newCallAuthority)
import Max.Execution.Types (ExecutionStep (..), StepReservation (..))
import Max.Jobs qualified as Jobs
import Max.LLM.Types (ChatMessage (..))
import Max.Node.Events qualified as Events
import Max.Node.Render (renderEvents, renderOpenTasks, selectEventObservation)
import Max.Node.Router qualified as Router
import Max.Tasks (TurnRuntime, advanceTurnObservation, saveTurnObservation, turnEvents, turnObservationCursor, turnRuntimeAgentTurn)
import Max.ToolContext (ToolContext, toolClearedAt, toolGroupId)
import Max.Turn.Types (AgentTurnId (..), AgentTurnRef (..))
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
        (observeAgentInputs jobs)
        (\turn -> turnEvents turn >>= (`Events.awaitInterrupt` Events.noPending))
        (\turn -> liftIO . atomically $ turnEvents turn >>= Events.tryFinish)
        ( \turn context -> liftIO $ do
            origin <- Jobs.resultOrigin jobs turn context
            pure (Just ExecutionResults {erDeliver = \ref value media -> atomically (Router.deliverResult jobs.resultRouter origin ref value media), erClose = atomically (Router.closeTask jobs.resultRouter origin.target)})
        )
        (\turn -> renderOpenTasks <$> liftIO (Jobs.otherOpenTasks jobs turn))
    )
    (Just (liftIO . Jobs.acquireGuestSlot jobs . (.atrTurnId)))

-- | One poll shares 200 messages/about 32k tokens across public evidence and
-- owned node events. Reserve room for both recovery notices. Archiving overflow
-- and acknowledging its receipts share STM, so closure cannot lose it or relay
-- it a second time. The archive belongs only to this task's lifetime.
observeAgentInputs :: (WithConnection :> es, IOE :> es) => Jobs.Jobs -> TurnRuntime -> ToolContext -> Eff es [ChatMessage]
observeAgentInputs jobs turn context = do
  let scope = conversationScopeFor (toolGroupId context)
      owner = (turnRuntimeAgentTurn turn).atrTurnId
      json value = TE.decodeUtf8 (LBS.toStrict (encode value))
  cursor <- liftIO (turnObservationCursor turn)
  cut <- traverse (readPublishedAfter scope owner (toolClearedAt context)) cursor
  liftIO . atomically $ do
    Jobs.flushJobEvents jobs owner
    target <- turnEvents turn
    events <- Router.observeAllEvents jobs.resultRouter target
    let (selected, omitted) = selectEventObservation 198 29900 events
    nodeMessages <-
      if null omitted
        then pure selected
        else do
          batch <- saveTurnObservation turn (json [object ["sequence" .= event.sequence, "messages" .= renderEvents [event]] | event <- omitted])
          let recovery = readLink (ReadCursor 1 (conversationStorageId scope) (Observation owner.unAgentTurnId batch 0) Nothing Nothing Nothing False 0 100)
          pure (selected <> [MsgUser (json (object ["unobserved_node_events" .= length omitted, "urgent_events" .= length (filter (Events.wakes Events.noPending . (.body)) omitted), "context_read" .= recovery]))])
    published <- case (cursor, cut) of
      (Just after, Just frozen) -> do
        advanceTurnObservation turn frozen.through
        pure (renderPublishedWithin (200 - length nodeMessages) (32000 - estimateMessagesTokens nodeMessages) scope (toolClearedAt context) after frozen)
      _ -> pure []
    pure (published <> nodeMessages)

executionAdmission :: (IOE :> es) => Jobs.Jobs -> ExecutionAdmission es
executionAdmission jobs =
  ExecutionAdmission
    { eaReserveRound = \turn -> liftIO (Jobs.decideJobStep jobs turn.atrTurnId (ExecutionWork ReserveRound)),
      eaCheck = \turn -> liftIO (Jobs.authorizeJobStep jobs turn.atrTurnId ExecutionCheckpoint),
      eaAdmitTool = \turn step -> liftIO (Jobs.decideJobStep jobs turn.atrTurnId step),
      eaCallAuthority = \turn tool -> liftIO $ Just <$> newCallAuthority turn.atrTurnId tool (Jobs.authorizeJobStep jobs turn.atrTurnId (ExecutionWork CheckOnly))
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
