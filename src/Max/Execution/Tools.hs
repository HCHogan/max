{-# LANGUAGE RankNTypes #-}

-- | Host execution shared by model protocol and guest adapters. No LLM or SQL.
module Max.Execution.Tools
  ( ExecutionSession,
    ExecutionHooks (..),
    ToolRequest (..),
    ToolBatch (..),
    newExecutionSession,
    setExecutionResultSink,
    executionHooks,
    executionEventTask,
    hoistExecutionHooks,
    freshExecutionLabel,
    executeToolBatch,
    launchCall,
    launchYieldingCall,
    Wake (..),
    awaitWake,
    awaitExecution,
    awaitExecutionUntil,
    parked,
    ProgramControl (..),
    registerProgram,
    unregisterProgram,
    controlProgram,
    closeExecutionSession,
    waitExecution,
    drainExecutionCompletions,
    hasDetachedExecutions,
    withExecutionRecord,
    outcomeName,
    outcomeEnvelope,
  )
where

import Control.Concurrent.Async qualified as Async
import Control.Concurrent.STM qualified as STM
import Control.Exception (fromException)
import Control.Exception qualified as Exception
import Control.Monad (unless, void, when)
import Data.Aeson (Value (..), object, toJSON, (.=))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Foldable (for_)
import Data.List (find)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (getCurrentTime)
import Effectful
import Effectful.Concurrent.Async (Async, Concurrent, async, asyncWithUnmask, cancel, waitCatch)
import Effectful.Concurrent.STM
  ( TVar,
    atomically,
    check,
    modifyTVar',
    newTQueueIO,
    newTVarIO,
    readTVar,
    readTVarIO,
    writeTVar,
  )
import Effectful.Exception
  ( Exception,
    SomeException,
    bracket_,
    catch,
    finally,
    mask,
    onException,
    throwIO,
    try,
  )
import Max.Agent.Execution
import Max.Effects.Tools (Tools, invokeToolWithAuthority)
import Max.Execution.Authority (CallAuthority, revokeCallAuthority)
import Max.Execution.Types
import Max.Node.Events qualified as Events
import Max.Node.Executor qualified as Executor
import Max.Tasks
  ( TaskCancelled (..),
    TurnRuntime,
    checkTurnCancellation,
    finishTurnCall,
    nextExecutionOrdinal,
    parkTurn,
    retainTurnWork,
    startTurnCall,
    turnEvents,
    turnExecutor,
    turnRuntimeAgentTurn,
  )
import Max.Tool.Control
  ( LoopControl (..),
    controlSkillLoads,
  )
import Max.Tool.Types
import Max.Turn.Types (AgentTurnRef (..), resultHandleText)
import OneBot.Types (GroupId)

data ToolRequest = ToolRequest
  { trCallId :: !Text,
    trName :: !Text,
    trArguments :: !Value
  }
  deriving stock (Show, Eq)

-- | Assembly supplies the same admission/journal implementation to both paths.
data ExecutionHooks es = ExecutionHooks
  { ehCheck :: Eff es (),
    ehStart :: ExecutionStep -> JournalStart -> Eff es (Maybe JournalExecution),
    ehFinish :: JournalExecution -> JournalFinish -> Eff es (),
    ehAcquireGuest :: Eff es (Maybe (IO ())),
    ehInterrupt :: STM.STM (),
    ehEvents :: STM.STM (Maybe Events.Task),
    ehRetain :: Async ToolInvocation -> Async ToolInvocation -> Eff es (),
    ehActor :: IO (Maybe Executor.Actor),
    ehCallAuthority :: Text -> Eff es (Maybe CallAuthority),
    -- | Entered around every wait on futures, returning the exit. The turn
    -- uses it to tell its silence watchdog it is parked, not stalled.
    ehPark :: IO (IO ())
  }

executionHooks :: (IOE :> es) => ExecutionAdmission es -> ExecutionJournal es -> GroupId -> TurnRuntime -> ExecutionHooks es
executionHooks admission journal group turn =
  ExecutionHooks
    { ehCheck = do
        liftIO (checkTurnCancellation turn)
        active <- admission.eaCheck (turnRuntimeAgentTurn turn)
        unless active (throwIO TaskCancelled),
      ehStart = \step start -> do
        let ref = turnRuntimeAgentTurn turn
        prepared <- journal.ejPrepare group start
        admission.eaAdmitTool ref step >>= \case
          Admitted -> pure ()
          OverBudget -> throwIO CallBudgetExhausted
          Refused -> throwIO TaskCancelled
        ordinal <- liftIO (nextExecutionOrdinal turn)
        now <- liftIO getCurrentTime
        liftIO (startTurnCall turn ordinal prepared.jsToolRef)
        pure (Just (JournalExecution ref ordinal prepared now)),
      ehFinish = \row result -> do
        liftIO (finishTurnCall turn row.jeExecutionOrdinal)
        journal.ejFinish row result,
      ehAcquireGuest = pure (Just (pure ())),
      ehInterrupt = STM.retry,
      ehEvents = Just <$> turnEvents turn,
      ehRetain = \call delivery -> liftIO (retainTurnWork turn (Async.cancel delivery) (Async.cancel call) (void (Async.waitCatchSTM delivery))),
      ehActor = Just <$> turnExecutor turn,
      ehPark = parkTurn turn,
      ehCallAuthority = admission.eaCallAuthority (turnRuntimeAgentTurn turn)
    }

hoistExecutionHooks :: (forall x. Eff es x -> Eff target x) -> ExecutionHooks es -> ExecutionHooks target
hoistExecutionHooks lower hooks =
  ExecutionHooks
    { ehCheck = lower hooks.ehCheck,
      ehStart = \step -> lower . hooks.ehStart step,
      ehFinish = \row -> lower . hooks.ehFinish row,
      ehAcquireGuest = lower hooks.ehAcquireGuest,
      ehInterrupt = hooks.ehInterrupt,
      ehEvents = hooks.ehEvents,
      ehRetain = \call -> lower . hooks.ehRetain call,
      ehActor = hooks.ehActor,
      ehCallAuthority = lower . hooks.ehCallAuthority,
      ehPark = hooks.ehPark
    }

-- | Admission refused a call because its agent tree's budget is spent. The
-- call is rejected before any effect; the agent itself keeps running.
data CallBudgetExhausted = CallBudgetExhausted deriving stock (Show)

instance Exception CallBudgetExhausted

data ExecutionSession = ExecutionSession
  { remaining :: !(TVar (Maybe Int)),
    sequenceNumber :: !(TVar Integer),
    gate :: !(TVar ([(Integer, Bool)], Int, Bool)),
    programs :: !(TVar (Map Text ProgramControl)),
    nativeFutures :: !(TVar (Map Text NativeFuture)),
    events :: !Events.Task,
    callHandles :: !(TVar (Map Text Text)),
    resultSink :: !(TVar (Maybe (Text -> ToolInvocation -> IO ()))),
    completions :: !(STM.TQueue (Text, ToolInvocation))
  }

newExecutionSession :: (Concurrent :> es) => Maybe Int -> Eff es ExecutionSession
newExecutionSession limit =
  ExecutionSession <$> newTVarIO (max 0 <$> limit) <*> newTVarIO 0 <*> newTVarIO ([], 0, False) <*> newTVarIO Map.empty <*> newTVarIO Map.empty <*> atomically (Events.newNode >>= Events.newTask) <*> newTVarIO Map.empty <*> newTVarIO Nothing <*> newTQueueIO

data NativeFuture = NativeFuture
  { worker :: !(Async ToolInvocation),
    settlement :: !(Events.Future (Either SomeException ToolInvocation)),
    reference :: !Text,
    yieldGate :: !(STM.STM ())
  }

executionEventTask :: ExecutionSession -> ExecutionHooks es -> STM.STM Events.Task
executionEventTask session hooks = fromMaybe session.events <$> hooks.ehEvents

setExecutionResultSink :: (Concurrent :> es) => ExecutionSession -> (Text -> ToolInvocation -> IO ()) -> Eff es ()
setExecutionResultSink session sink = atomically (writeTVar session.resultSink (Just sink))

-- | Process-local control of a retained guest. Only its owner session can
-- resolve the handle; controls contain no model-supplied authority.
data ProgramControl = ProgramControl
  { pcResume :: IO ToolInvocation,
    pcCancel :: IO ToolInvocation
  }

registerProgram :: (Concurrent :> es) => ExecutionSession -> Text -> ProgramControl -> Eff es ()
registerProgram session ref control = atomically $ modifyTVar' session.programs (Map.insert ref control)

unregisterProgram :: (Concurrent :> es) => ExecutionSession -> Text -> Eff es ()
unregisterProgram session ref = atomically $ modifyTVar' session.programs (Map.delete ref)

controlProgram :: (Concurrent :> es, IOE :> es) => ExecutionSession -> Bool -> Text -> Eff es ToolInvocation
controlProgram session resume ref = do
  found <- Map.lookup ref <$> readTVarIO session.programs
  case found of
    Nothing -> pure (rejected "unknown_program" "program is not live in this task")
    Just control -> liftIO (if resume then control.pcResume else control.pcCancel)

-- | A task's paused programs have no consumer after its final answer.
closeExecutionSession :: (Concurrent :> es, IOE :> es) => ExecutionSession -> Eff es ()
closeExecutionSession session = do
  active <- atomically $ do
    active <- readTVar session.programs
    writeTVar session.programs Map.empty
    pure active
  mapM_ (liftIO . pcCancel) active

data Wake k = Settled ![(k, Either SomeException ToolInvocation)] | Interrupted

-- | Shared waiting protocol. Native readiness is proved by a selected node
-- event; guest-private promises stay below the model event stream (§4).
-- Interruption changes ownership, never cancels the pending computations.
awaitWake :: STM.STM () -> (future -> STM.STM (Maybe (Either SomeException ToolInvocation))) -> Map k future -> STM.STM (Wake k)
awaitWake interrupt poll pending =
  (interrupt >> pure Interrupted) `STM.orElse` do
    ready <- traverse poll pending
    let completed = [(key, result) | (key, Just result) <- Map.toList ready]
    STM.check (not (null completed))
    pure (Settled completed)

awaitNative :: STM.STM () -> Map k NativeFuture -> STM.STM (Wake k)
awaitNative interrupt pending = awaitWake interrupt (Events.pollFuture selection . (.settlement)) pending
  where
    selection = Events.noPending {Events.calls = Set.fromList (map (.reference) (Map.elems pending))}

-- | A native await and a guest await release the same node executor. The
-- caller keeps the future; cancellation here only abandons its scheduling slot.
awaitExecution :: (IOE :> es) => ExecutionHooks es -> Bool -> STM.STM a -> Eff es a
awaitExecution hooks immediate ready = do
  deadline <- liftIO Executor.shortDeadline
  awaitExecutionUntil hooks immediate deadline ready

awaitExecutionUntil :: (IOE :> es) => ExecutionHooks es -> Bool -> STM.STM () -> STM.STM a -> Eff es a
awaitExecutionUntil hooks immediate deadline ready = do
  actor <- liftIO hooks.ehActor
  case actor of
    Nothing -> liftIO (parked hooks (STM.atomically ready))
    Just owner -> do
      result <- liftIO (parked hooks (Executor.await owner immediate deadline ready))
      maybe (throwIO TaskCancelled) pure result

-- | Run a wait on futures as parked time for the turn's silence watchdog.
parked :: ExecutionHooks es -> IO a -> IO a
parked hooks action = Exception.mask $ \restore -> do
  leave <- hooks.ehPark
  restore action `Exception.finally` leave

-- | Labels are local to this session; result ordinals belong to the turn.
freshExecutionLabel :: (Concurrent :> es) => ExecutionSession -> Text -> Eff es Text
freshExecutionLabel session prefix = atomically $ do
  n <- readTVar session.sequenceNumber
  writeTVar session.sequenceNumber (n + 1)
  pure (prefix <> ":" <> T.pack (show n))

data ToolBatch = ToolBatch
  { tbInvocations :: ![ToolInvocation],
    tbOverBudget :: !Bool
  }
  deriving stock (Show)

-- | Native rounds join all calls, but guest programs can wait for any one of
-- the same futures. Admission and journal start precede worker creation.
executeToolBatch :: (Tools :> es, Concurrent :> es, IOE :> es) => ExecutionSession -> ExecutionHooks es -> [CatalogTool] -> [ToolRequest] -> Eff es ToolBatch
executeToolBatch session hooks catalog requests = mask $ \restore -> do
  owned <- newTVarIO Map.empty
  let cleanup = readTVarIO owned >>= mapM_ (cancel . (.worker)) . reverse . Map.elems
      detach index request future = do
        let worker = future.worker
        handles <- readTVarIO session.callHandles
        ref <- maybe (freshExecutionLabel session "result") pure (Map.lookup request.trCallId handles)
        watcher <- asyncWithUnmask $ \unmask ->
          ( do
              result <- unmask (waitCatch worker)
              let invocation = either (\exception -> ToolInvocation (ToolOutcomeUnknown (ToolFault "interrupted" (T.pack (show exception)) RetryUnsafe)) ContinueLoop) id result
              sink <- readTVarIO session.resultSink
              case sink of
                Nothing -> atomically (STM.writeTQueue session.completions (ref, invocation))
                Just deliver -> unmask (liftIO (deliver ref invocation))
              pure invocation
          )
            `finally` cancel worker
        hooks.ehRetain worker watcher `onException` cancel watcher
        atomically $ do
          -- The model now orders its later calls around this one.
          future.yieldGate
          modifyTVar' session.nativeFutures (Map.insert ref future)
          modifyTVar' owned (Map.delete index)
        pure (runningInvocation ref)
      asyncTool request = maybe False ((== AsyncTool) . (.ctDefinition.tdAwait)) (find ((== ToolRef request.trName) . (.ctDefinition.tdRef)) catalog)
      requestMap = Map.fromList (zip [0 :: Int ..] requests)
      join deadline completed = do
        pending <- readTVarIO owned
        if Map.null pending
          then pure completed
          else do
            let interrupt = if all (asyncTool . (requestMap Map.!)) (Map.keys pending) then hooks.ehInterrupt else STM.retry
            wake <- awaitExecutionUntil hooks (any (asyncTool . (requestMap Map.!)) (Map.keys pending)) deadline (awaitNative interrupt pending)
            case wake of
              Settled ready -> do
                values <- traverse (\(index, value) -> (index,) <$> either throwIO pure value) ready
                atomically $ modifyTVar' owned (\active -> foldr Map.delete active (map fst ready))
                join deadline (completed <> Map.fromList values)
              Interrupted -> do
                values <- traverse (\(index, worker) -> (index,) <$> detach index (requestMap Map.! index) worker) (Map.toList pending)
                pure (completed <> Map.fromList values)
  ( do
      mapM_
        ( \(index, request) -> do
            future <- launchNativeCall session hooks catalog request
            atomically $ modifyTVar' owned (Map.insert index future)
        )
        (Map.toList requestMap)
      deadline <- liftIO Executor.shortDeadline
      results <- Map.elems <$> restore (join deadline Map.empty)
      pure (ToolBatch results (any spent results))
    )
    `finally` cleanup
  where
    spent invocation = case invocation.tiOutcome of
      ToolRejected fault -> fault.tfCode == "call_budget_exhausted"
      _ -> False

runningInvocation :: Text -> ToolInvocation
runningInvocation ref = ToolInvocation (ToolSucceeded (object ["status" .= ("running" :: Text), "result" .= ref])) ContinueLoop

waitExecution :: (Concurrent :> es, IOE :> es) => ExecutionSession -> ExecutionHooks es -> Text -> Eff es ToolInvocation
waitExecution session hooks ref = do
  active <- Map.lookup ref <$> readTVarIO session.nativeFutures
  case active of
    Nothing -> pure (rejected "unknown_execution" "result is not retained in this task")
    Just future ->
      awaitExecution hooks True (awaitNative hooks.ehInterrupt (Map.singleton ref future)) >>= \case
        Interrupted -> pure (runningInvocation ref)
        -- The retained completion owns its media delivery. Waiting again only
        -- returns the value, even if it wins the race with that delivery.
        Settled [(_, result)] -> (\invocation -> invocation {tiMedia = []}) <$> either throwIO pure result
        _ -> error "single future wake cardinality"

hasDetachedExecutions :: (Concurrent :> es) => ExecutionSession -> Eff es Bool
hasDetachedExecutions session = not . Map.null <$> readTVarIO session.nativeFutures

drainExecutionCompletions :: (Concurrent :> es) => ExecutionSession -> Eff es [(Text, ToolInvocation)]
drainExecutionCompletions session = atomically (STM.flushTQueue session.completions)

launchCall :: (Tools :> es, Concurrent :> es, IOE :> es) => ExecutionSession -> ExecutionHooks es -> [CatalogTool] -> ToolRequest -> Eff es (Async ToolInvocation)
launchCall session hooks catalog request = fst <$> launchYieldingCall session hooks catalog request

-- | Also returns the action that takes the call out of the session's call
-- ordering once the model no longer awaits it (see 'launchCallWith').
launchYieldingCall :: (Tools :> es, Concurrent :> es, IOE :> es) => ExecutionSession -> ExecutionHooks es -> [CatalogTool] -> ToolRequest -> Eff es (Async ToolInvocation, STM.STM ())
launchYieldingCall = launchCallWith (const (pure ()))

launchNativeCall :: (Tools :> es, Concurrent :> es, IOE :> es) => ExecutionSession -> ExecutionHooks es -> [CatalogTool] -> ToolRequest -> Eff es NativeFuture
launchNativeCall session hooks catalog request = do
  target <- atomically (executionEventTask session hooks)
  settlement <- atomically (Events.newFuture target)
  reference <- freshExecutionLabel session "native"
  let publish result = do
        let invocation = either (\exception -> ToolInvocation (ToolOutcomeUnknown (ToolFault "interrupted" (T.pack (show exception)) RetryUnsafe)) ContinueLoop) id result
        atomically . void $ Events.settleFuture settlement (Events.Settled reference (outcomeEnvelope invocation.tiOutcome) invocation.tiMedia) result
  (worker, yieldGate) <- launchCallWith publish session hooks catalog request
  pure (NativeFuture worker settlement reference yieldGate)

-- | Calls enter the session's gate in arrival order: shared calls run together,
-- an exclusive call runs alone. A shared call whose await was interrupted, or
-- whose program paused, yields its place: it stops holding back later calls,
-- because the model has taken over their ordering, as with a detached agent.
-- Exclusive calls keep their slot; they may share a stateful resource such as
-- a browser session, and their deadlines are short.
launchCallWith :: (Tools :> es, Concurrent :> es, IOE :> es) => (Either SomeException ToolInvocation -> Eff es ()) -> ExecutionSession -> ExecutionHooks es -> [CatalogTool] -> ToolRequest -> Eff es (Async ToolInvocation, STM.STM ())
launchCallWith publish session hooks catalog request = mask $ \_ -> do
  hooks.ehCheck
  let view = find ((== ToolRef request.trName) . (.ctDefinition.tdRef)) catalog
      cost = if maybe WorkCall (.ctDefinition.tdCallMode) view == WorkCall then 1 else 0
      shared = maybe False ((`elem` [ParallelSafe, ParallelIndependent]) . (.ctDefinition.tdParallelism)) view
      start = maybe (unknownJournalStart request) (catalogJournalStart request) view
      step = if cost == 0 then ExecutionCheckpoint else ExecutionWork ReserveCall
      notify action = mask $ \restore -> do
        result <- try (restore action)
        publish result
        either throwIO pure result
  reserved <- atomically $ do
    budget <- readTVar session.remaining
    case budget of
      Just available | cost > available -> pure False
      _ -> writeTVar session.remaining (subtract cost <$> budget) >> pure True
  if not reserved
    then (,pure ()) <$> async (notify (pure budgetSpent))
    else do
      let refund = atomically $ modifyTVar' session.remaining (fmap (+ cost))
      admitted <- try (hooks.ehStart step start) `onException` refund
      case admitted of
        Left CallBudgetExhausted -> refund >> ((,pure ()) <$> async (notify (pure budgetSpent)))
        Right row -> do
          ref <- maybe (freshExecutionLabel session "result") (pure . (\entry -> resultHandleText entry.jeTurn.atrTurnOrdinal entry.jeExecutionOrdinal)) row
          atomically $ modifyTVar' session.callHandles (Map.insert request.trCallId ref)
          started <- newTVarIO False
          held <- newTVarIO False
          yielded <- newTVarIO False
          ticket <- atomically $ do
            ticket <- readTVar session.sequenceNumber
            writeTVar session.sequenceNumber (ticket + 1)
            modifyTVar' session.gate (\(queue, readers, writer) -> (queue <> [(ticket, shared)], readers, writer))
            pure ticket
          let dequeue = atomically $ modifyTVar' session.gate (\(queue, readers, writer) -> (filter ((/= ticket) . fst) queue, readers, writer))
              acquire = atomically $ do
                (queue, readers, writer) <- readTVar session.gate
                gone <- readTVar yielded
                if gone
                  then do
                    -- Out of the ordering, but never beside a running exclusive call.
                    check (not writer)
                    writeTVar session.gate (filter ((/= ticket) . fst) queue, readers, writer)
                  else do
                    let before = takeWhile ((/= ticket) . fst) queue
                    check (not writer && (if shared then all snd before else null before && readers == 0))
                    writeTVar session.gate (filter ((/= ticket) . fst) queue, readers + if shared then 1 else 0, not shared)
                    writeTVar held True
              release = atomically $ do
                holding <- readTVar held
                when holding $ do
                  writeTVar held False
                  modifyTVar' session.gate (\(queue, readers, _) -> (queue, readers - if shared then 1 else 0, False))
              -- Idempotent; a no-op for exclusive and already finished calls.
              yieldGate = when shared $ do
                writeTVar yielded True
                holding <- readTVar held
                writeTVar held False
                modifyTVar' session.gate (\(queue, readers, writer) -> (filter ((/= ticket) . fst) queue, if holding then readers - 1 else readers, writer))
              interrupted (exception :: SomeException) = case fromException exception of
                Just Async.AsyncCancelled -> do
                  began <- readTVarIO started
                  pure $
                    if began
                      then ToolInvocation (ToolOutcomeUnknown (ToolFault "cancelled" "call cancelled after it may have started effects" RetryUnsafe)) ContinueLoop
                      else rejected "cancelled" "call cancelled before starting"
                Nothing -> do
                  for_ row $ \entry -> hooks.ehFinish entry (JournalOutcomeUnknown "interrupted" (T.pack (show exception)))
                  throwIO exception
              run authority unmask = do
                invocation <-
                  unmask
                    ( bracket_ acquire release $ do
                        atomically (writeTVar started True)
                        case view of
                          Nothing -> pure (rejected "unknown_tool" ("tool is outside the execution catalog: " <> request.trName))
                          Just _ -> invokeToolWithAuthority authority request.trName request.trArguments
                    )
                    `finally` for_ authority (liftIO . revokeCallAuthority)
                    `catch` interrupted
                for_ row $ \entry -> hooks.ehFinish entry (journalFinish (journalControl invocation))
                pure invocation {tiOutcome = stripJournalMetadata invocation.tiOutcome}
          authority <- hooks.ehCallAuthority request.trName `onException` dequeue
          let cleanup = for_ authority (liftIO . revokeCallAuthority) >> dequeue
          worker <- asyncWithUnmask (\unmask -> notify (run authority unmask `finally` cleanup)) `onException` cleanup
          pure (worker, yieldGate)
  where
    budgetSpent = rejected "call_budget_exhausted" "工具调用预算已经用完，不能再执行这个调用；直接根据已有信息给出最终回复"

-- | Admission is local. Record the outcome after the cancellable body; a
-- diagnostic failure must not reclassify a completed external effect.
withExecutionRecord :: ExecutionHooks es -> ExecutionStep -> JournalStart -> (Maybe JournalExecution -> Eff es (a, ToolInvocation)) -> Eff es (a, ToolInvocation)
withExecutionRecord hooks step start body = mask $ \restore -> do
  hooks.ehCheck
  row <- hooks.ehStart step start
  (value, invocation) <-
    restore (body row)
      `catch` \(exception :: SomeException) -> do
        for_ row $ \entry -> hooks.ehFinish entry (JournalOutcomeUnknown "interrupted" (T.pack (show exception)))
        throwIO exception
  for_ row $ \entry -> hooks.ehFinish entry (journalFinish (journalControl invocation))
  pure (value, invocation {tiOutcome = stripJournalMetadata invocation.tiOutcome})

rejected :: Text -> Text -> ToolInvocation
rejected code message = ToolInvocation (ToolRejected (ToolFault code message RetrySafe)) ContinueLoop

-- | Preserve classification across the guest ABI; never turn unknown into an
-- apparently safe error. Trusted control and journal metadata are not JSON.
outcomeEnvelope :: ToolOutcome -> Value
outcomeEnvelope outcome =
  object $
    ["outcome" .= outcomeName outcome] <> case outcome of
      ToolSucceeded value -> ["value" .= value]
      ToolCommitted value -> ["value" .= value]
      ToolRejected fault -> failure fault
      ToolFailedBeforeEffect fault -> failure fault
      ToolOutcomeUnknown fault -> failure fault
  where
    failure fault = ["error" .= object ["code" .= fault.tfCode, "message" .= fault.tfMessage, "retry" .= retryClassText fault.tfRetryClass]]

outcomeName :: ToolOutcome -> Text
outcomeName = \case
  ToolRejected {} -> "rejected"
  ToolFailedBeforeEffect {} -> "failed-before-effect"
  ToolSucceeded {} -> "succeeded"
  ToolCommitted {} -> "committed"
  ToolOutcomeUnknown {} -> "outcome-unknown"

-- Activation evidence comes only from the typed host channel.
journalControl :: ToolInvocation -> ToolOutcome
journalControl invocation = case controlSkillLoads invocation.tiControl of
  [] -> invocation.tiOutcome
  loads -> case invocation.tiOutcome of
    ToolSucceeded (Object fields) -> ToolSucceeded (Object (KeyMap.insert "_max_journal_observed_manifest" (object ["skill_loads" .= loads]) fields))
    ToolCommitted (Object fields) -> ToolCommitted (Object (KeyMap.insert "_max_journal_observed_manifest" (object ["skill_loads" .= loads]) fields))
    other -> other

catalogJournalStart :: ToolRequest -> CatalogTool -> JournalStart
catalogJournalStart tc view =
  JournalStart
    { jsCallId = tc.trCallId,
      jsToolRef = tc.trName,
      jsSchemaVersion = view.ctDefinition.tdSchemaVersion.unSchemaVersion,
      jsSchemaHash = view.ctSchemaHash.unSchemaHash,
      jsInput = case tc.trArguments of Object fields -> Object (KeyMap.delete "_max_host_network_mode" fields); value -> value,
      jsEffectLabels = toJSON (map effectLabel (Set.toList view.ctDefinition.tdEffects)),
      jsRetryClass = retryClassText view.ctDefinition.tdRetryClass
    }

unknownJournalStart :: ToolRequest -> JournalStart
unknownJournalStart tc =
  JournalStart tc.trCallId tc.trName 0 "unknown" tc.trArguments (toJSON ([] :: [Value])) "safe"

effectLabel :: ToolEffect -> Value
effectLabel = \case
  EffectRead domain -> object ["kind" .= ("read" :: Text), "domain" .= domain]
  EffectWrite domain -> object ["kind" .= ("write" :: Text), "domain" .= domain]
  EffectSend domain -> object ["kind" .= ("send" :: Text), "domain" .= domain]
  EffectLLM -> object ["kind" .= ("llm" :: Text)]
  EffectReflect -> object ["kind" .= ("reflect" :: Text)]

retryClassText :: ToolRetryClass -> Text
retryClassText = \case
  RetrySafe -> "safe"
  RetryIdempotent -> "idempotent"
  RetryUnsafe -> "unsafe"

journalFinish :: ToolOutcome -> JournalFinish
journalFinish = \case
  ToolRejected fault -> JournalRejected fault.tfCode fault.tfMessage
  ToolFailedBeforeEffect fault -> JournalFailed fault.tfCode fault.tfMessage
  ToolSucceeded value -> JournalSucceeded value
  ToolCommitted value -> JournalCommitted value
  ToolOutcomeUnknown fault -> JournalOutcomeUnknown fault.tfCode fault.tfMessage

stripJournalMetadata :: ToolOutcome -> ToolOutcome
stripJournalMetadata = \case
  ToolSucceeded value -> ToolSucceeded (stripValue value)
  ToolCommitted value -> ToolCommitted (stripValue value)
  other -> other
  where
    stripValue (Object fields) =
      Object
        ( KeyMap.delete "_max_journal_canonical_message_id" $
            KeyMap.delete "_max_journal_observed_manifest" fields
        )
    stripValue value = value
