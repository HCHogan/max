-- | Wasm adapter for the same host executor used by native model calls.
module Max.CodeMode.Execution
  ( CodeModeResult (..),
    CodeModeCall (..),
    WasmProgram (..),
    runWasmTools,
    runWasmProgram,
    codeModeInvocation,
  )
where

import Control.Concurrent.Async qualified as Async
import Control.Concurrent.STM
import Control.Exception qualified as Exception
import Control.Monad (forM, forM_, void)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.Aeson
  ( Value (..),
    encode,
    object,
    toJSON,
    (.=),
  )
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (parseJSON, parseMaybe)
import Data.ByteString (ByteString)
import Data.ByteString.Base16 qualified as Base16
import Data.ByteString.Lazy qualified as LBS
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes, fromMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Effectful
import Effectful.Concurrent (Concurrent, threadDelay)
import Effectful.Concurrent.Async (async, asyncWithUnmask, cancel)
import Effectful.Exception (bracket, catch, finally, mask, onException, throwIO)
import Max.CodeMode.Wasm
import Max.Effects.Tools (Tools)
import Max.Execution.Tools
import Max.Execution.Types
import Max.Node.Executor qualified as Executor
import Max.Skill.Contract (Contract, validateValue)
import Max.Tasks (TaskCancelled (..))
import Max.Tool.Control
  ( LoopControl (..),
    mergeControls,
  )
import Max.Tool.Media (InlineMedia)
import Max.Tool.Types
import Max.Turn.Types (AgentTurnRef (..), resultHandleText)

-- | Bounded receipts; full leaf results remain in the journal/artifact store.
data CodeModeCall = CodeModeCall
  { ccLabel :: !Text,
    ccTool :: !Text,
    ccOutcome :: !Text
  }
  deriving stock (Show, Eq)

data CodeModeResult = CodeModeResult
  { cmExit :: !WasmExit,
    cmCalls :: ![CodeModeCall],
    cmControl :: !LoopControl,
    cmOutput :: !(Maybe Value),
    cmSubmittedCalls :: !Int,
    cmOverBudget :: !Bool,
    cmRunRef :: !Text,
    cmWorkflow :: !(Maybe Value),
    cmMedia :: ![InlineMedia]
  }
  deriving stock (Show, Eq)

-- | Host-authored submission, not a decoder for model-provided module bytes.
data WasmProgram = WasmProgram
  { wpModule :: !ByteString,
    wpInput :: !(Maybe ByteString),
    wpEvidence :: !Value,
    wpOutputContract :: !(Maybe Contract),
    wpWorkflow :: !(Maybe Value)
  }

runWasmTools :: (Tools :> es, Concurrent :> es, IOE :> es) => ExecutionSession -> ExecutionHooks es -> [CatalogTool] -> WasmLimits -> ByteString -> Eff es CodeModeResult
runWasmTools session hooks catalog limits binary = runWasmProgram session hooks catalog limits (WasmProgram binary Nothing Null Nothing Nothing)

-- | Orchestration enters outside the leaf gate. Registering this as a leaf Tool
-- runner would recursively acquire that gate and deadlock.
runWasmProgram :: (Tools :> es, Concurrent :> es, IOE :> es) => ExecutionSession -> ExecutionHooks es -> [CatalogTool] -> WasmLimits -> WasmProgram -> Eff es CodeModeResult
runWasmProgram session hooks catalog limits program = mask $ \restore -> do
  replies <- liftIO newEmptyTMVarIO
  resumes <- liftIO newEmptyTMVarIO
  paused <- liftIO (newTVarIO False)
  owner <- liftIO newEmptyTMVarIO
  parentActor <- liftIO hooks.ehActor
  guestActor <- liftIO (traverse (atomically . Executor.guestActor) parentActor)
  let guestHooks = hooks {ehActor = pure guestActor}
      waitReply worker =
        let ready = takeTMVar replies `orElse` (Async.waitCatchSTM worker >>= either throwSTM pure)
         in case parentActor of
              Nothing -> atomically ready
              Just actor -> Executor.await actor True retry ready >>= maybe (Exception.throwIO TaskCancelled) pure
      install worker ref =
        registerProgram session ref $
          ProgramControl
            { pcResume = Exception.mask $ \restoreIO -> do
                accepted <- atomically $ do
                  waiting <- readTVar paused
                  if not waiting
                    then pure False
                    else do
                      writeTVar paused False
                      putTMVar resumes ()
                      pure True
                if accepted
                  then codeModeInvocation <$> restoreIO (waitReply worker)
                  else pure (ToolInvocation (ToolRejected (ToolFault "program_not_paused" "program is not paused" RetrySafe)) ContinueLoop),
              pcCancel = do
                Async.cancel worker
                result <- Async.waitCatch worker
                either Exception.throwIO (pure . codeModeInvocation) result
            }
      suspend result = do
        liftIO . atomically $ do
          writeTVar paused True
          putTMVar replies result
        awaitExecution guestHooks True (takeTMVar resumes)
  worker <- asyncWithUnmask $ \unmask -> unmask $ do
    self <- liftIO (atomically (readTMVar owner))
    result <-
      ( do
          forM_ guestActor $ \actor -> do
            entered <- liftIO (Executor.enter actor)
            if entered then pure () else throwIO TaskCancelled
          bracket hooks.ehAcquireGuest (mapM_ liftIO) $ \case
            Nothing -> pure (CodeModeResult (WasmRejected "live guest limit exceeded; retry later or use native tools") [] ContinueLoop Nothing 0 False "" program.wpWorkflow [])
            Just _ -> runAdmittedProgram session guestHooks catalog limits program (install self) suspend
      )
        `finally` liftIO (mapM_ (atomically . Executor.closeActor) guestActor)
    liftIO . atomically $ do
      writeTVar paused False
      _ <- tryPutTMVar replies result
      pure ()
    pure result
  liftIO (atomically (putTMVar owner worker))
  restore (liftIO (waitReply worker)) `onException` cancel worker

runAdmittedProgram :: (Tools :> es, Concurrent :> es, IOE :> es) => ExecutionSession -> ExecutionHooks es -> [CatalogTool] -> WasmLimits -> WasmProgram -> (Text -> Eff es ()) -> (CodeModeResult -> Eff es ()) -> Eff es CodeModeResult
runAdmittedProgram session hooks catalog limits program install suspend = do
  label <- freshExecutionLabel session "wasm"
  receipts <- liftIO (newTVarIO [])
  attachments <- liftIO (newTVarIO [])
  decisions <- liftIO (newTVarIO ContinueLoop)
  exhausted <- liftIO (newTVarIO False)
  submitted <- liftIO (newTVarIO 0)
  workers <- liftIO (newTVarIO Map.empty)
  seen <- liftIO (newTVarIO Set.empty)
  buffered <- liftIO (newTVarIO [])
  reference <- liftIO (newTVarIO label)
  let start =
        JournalStart
          label
          "host:wasm/v2"
          2
          "max-wasm-abi-v2"
          (object ["sha256" .= digest program.wpModule, "input_sha256" .= fmap digest program.wpInput, "program" .= program.wpEvidence, "fuel" .= limits.wlFuel, "memory_bytes" .= limits.wlMemoryBytes, "timeout_micros" .= limits.wlTimeoutMicros, "host_calls" .= limits.wlHostCalls])
          (toJSON ([] :: [Value]))
          "unsafe"
      record request invocation = liftIO . atomically $ do
        modifyTVar' receipts (CodeModeCall request.trCallId request.trName (outcomeName invocation.tiOutcome) :)
        modifyTVar' decisions (\previous -> mergeControls [previous, invocation.tiControl])
        modifyTVar' exhausted (|| isBudget invocation.tiOutcome)
        modifyTVar' attachments (<> invocation.tiMedia)
      cancelled = ToolInvocation (ToolOutcomeUnknown (ToolFault "cancelled" "program cancelled an in-flight call; effects may have started" RetryUnsafe)) ContinueLoop
      stop ident = do
        pending <- Map.lookup ident <$> liftIO (readTVarIO workers)
        forM pending $ \(request, worker) -> do
          cancel worker
          outcome <- liftIO (Async.waitCatch worker)
          let stopped = if request.trName == "$sleep" then ToolInvocation (ToolRejected (ToolFault "cancelled" "sleep cancelled" RetrySafe)) ContinueLoop else cancelled
              invocation = either (const stopped) id outcome
          record request invocation
          liftIO . atomically $ modifyTVar' workers (Map.delete ident)
          pure (ident, boundedOutcome invocation.tiOutcome)
      cleanup = liftIO (readTVarIO workers) >>= mapM_ (void . stop) . reverse . Map.keys
      launch (GuestCall ident name args) = mask $ \_ -> do
        request <- (\call -> ToolRequest call name args) <$> freshExecutionLabel session (label <> "/call")
        used <- liftIO (readTVarIO submitted)
        liftIO . atomically $ modifyTVar' submitted (+ 1)
        worker <-
          if used >= limits.wlHostCalls
            then async (pure (ToolInvocation (ToolRejected (ToolFault "guest_call_limit" "program leaf call limit exceeded" RetrySafe)) ContinueLoop))
            else do
              if name == "$sleep"
                then async $ case args of
                  Object fields
                    | Just ms <- KeyMap.lookup "ms" fields >>= parseMaybe (parseJSON @Int),
                      ms >= 0,
                      ms <= 21600000 ->
                        threadDelay (ms * 1000) >> pure (ToolInvocation (ToolSucceeded Null) ContinueLoop)
                  _ -> pure (ToolInvocation (ToolRejected (ToolFault "invalid_sleep" "invalid sleep duration" RetrySafe)) ContinueLoop)
                else launchCall session hooks catalog request
        liftIO . atomically $ modifyTVar' workers (Map.insert ident (request, worker))
      snapshot exit output = do
        calls <- reverse <$> liftIO (readTVarIO receipts)
        control <- liftIO (readTVarIO decisions)
        overBudget <- liftIO (readTVarIO exhausted)
        count <- liftIO (readTVarIO submitted)
        ref <- liftIO (readTVarIO reference)
        media <- liftIO . atomically $ do
          pending <- readTVar attachments
          writeTVar attachments []
          pure pending
        pure (CodeModeResult exit calls control output count overBudget ref program.wpWorkflow media)
      asyncTool name = name == "$sleep" || any (\entry -> entry.ctDefinition.tdRef == ToolRef name && entry.ctDefinition.tdAwait == AsyncTool) catalog
      pause queued = do
        active <- liftIO (readTVarIO workers)
        result <- snapshot WasmPaused (Just (object ["pending" .= ([object ["call" .= request.trCallId, "tool" .= request.trName, "status" .= ("running" :: Text)] | (request, _) <- Map.elems active] <> [object ["tool" .= call.gcTool, "status" .= ("queued" :: Text)] | call <- queued])]))
        suspend result
      pauseIfRequested allowed queued =
        if not allowed
          then pure ()
          else do
            interrupt <- liftIO . atomically $ (hooks.ehInterrupt >> pure True) `orElse` pure False
            if interrupt then pause queued else pure ()
      drive guest = \case
        GuestDone value -> pure (WasmCompleted, Just value)
        GuestTrap exit -> pure (exit, case exit of WasmTrapped detail -> Just (object ["error" .= detail]); _ -> Nothing)
        GuestCalls calls cancellations waiting -> do
          known <- liftIO (readTVarIO seen)
          active <- liftIO (readTVarIO workers)
          let ids = map gcId calls
              valid = all (> 0) ids && Set.size (Set.fromList ids) == length ids && all (`Set.notMember` known) ids && Map.size active + length calls <= 64 && waiting >= Map.size active + length calls && all (\call -> case call.gcArgs of Object _ -> True; _ -> False) calls
          if not valid
            then pure (WasmTrapped "invalid guest call set", Nothing)
            else do
              pauseIfRequested (all (asyncTool . (.trName) . fst) (Map.elems active) && any (asyncTool . gcTool) calls) calls
              liftIO . atomically $ modifyTVar' seen (<> Set.fromList ids)
              forM_ calls launch
              -- Cancellation completes the promise too: a program may catch it.
              cancelledResults <- catMaybes <$> traverse stop (reverse (Set.toList (Set.fromList cancellations)))
              pending <- liftIO (readTVarIO workers)
              previous <- liftIO (readTVarIO buffered)
              if Map.null pending && null cancelledResults && null previous
                then pure (WasmTrapped "guest waiting without in-flight calls", Nothing)
                else do
                  let interrupt = if all (asyncTool . (.trName) . fst) (Map.elems pending) then hooks.ehInterrupt else retry
                      collect = do
                        wake <- awaitExecution hooks (any (asyncTool . (.trName) . fst) (Map.elems pending)) (awaitWake interrupt Async.pollSTM (snd <$> pending))
                        case wake of
                          Interrupted -> pause [] >> collect
                          Settled ready -> pure [(ident, request, outcome) | (ident, outcome) <- ready, Just (request, _) <- [Map.lookup ident pending]]
                  completed <- if null cancelledResults && null previous then collect else pure []
                  outcomes <- forM completed $ \(ident, request, outcome) -> do
                    invocation <- either throwIO pure outcome
                    record request invocation
                    liftIO . atomically $ modifyTVar' workers (Map.delete ident)
                    pure (ident, boundedOutcome invocation.tiOutcome)
                  -- Deliver every ready completion that fits; retain the rest
                  -- until the next step without holding unrelated calls back.
                  let (chunk, rest) = resumeChunk (previous <> cancelledResults <> outcomes)
                  liftIO . atomically $ writeTVar buffered rest
                  remaining <- liftIO (readTVarIO workers)
                  pauseIfRequested (all (asyncTool . (.trName) . fst) (Map.elems remaining)) []
                  step <- liftIO (resumeGuest guest chunk)
                  drive guest step

  let run = do
        (result, _) <- withExecutionRecord hooks ExecutionCheckpoint start $ \row -> do
          let ref = maybe label (\entry -> resultHandleText entry.jeTurn.atrTurnOrdinal entry.jeExecutionOrdinal) row
          liftIO (atomically (writeTVar reference ref))
          install ref
          (exit, output) <- withGuest limits program.wpModule (fromMaybe "" program.wpInput) (\guest initial -> drive guest initial `finally` cleanup)
          let finalExit = case (exit, program.wpOutputContract) of
                (WasmCompleted, Just contract) | Left err <- validateValue contract (fromMaybe Null output) -> WasmTrapped ("workflow output contract: " <> err)
                _ -> exit
          result <- snapshot finalExit output
          pure (result, codeModeInvocation result)
        pure result
  ( run `catch` \(exception :: Exception.SomeException) -> case Exception.fromException exception of
      Just Async.AsyncCancelled -> snapshot (WasmTrapped "program cancelled") Nothing
      Nothing -> throwIO exception
    )
    `finally` (liftIO (readTVarIO reference) >>= unregisterProgram session)
  where
    digest = TE.decodeUtf8 . Base16.encode . SHA256.hash
    isBudget (ToolRejected fault) = fault.tfCode == "call_budget_exhausted"
    isBudget _ = False

codeModeInvocation :: CodeModeResult -> ToolInvocation
codeModeInvocation result = (ToolInvocation outcome result.cmControl) {tiMedia = result.cmMedia}
  where
    count = length result.cmCalls
    summary =
      object
        [ "run_ref" .= result.cmRunRef,
          "run" .= result.cmRunRef,
          "status" .= (if result.cmExit == WasmPaused then "paused" else "finished" :: Text),
          "pending" .= (case result.cmOutput of Just (Object fields) | result.cmExit == WasmPaused -> fromMaybe (Array mempty) (KeyMap.lookup "pending" fields); _ -> Array mempty),
          "workflow" .= result.cmWorkflow,
          "exit" .= T.pack (show result.cmExit),
          "value" .= result.cmOutput,
          "over_budget" .= result.cmOverBudget,
          "call_count" .= count,
          "submitted_calls" .= result.cmSubmittedCalls,
          "omitted_calls" .= max 0 (count - 128),
          "calls" .= [object ["call" .= c.ccLabel, "tool" .= c.ccTool, "outcome" .= c.ccOutcome] | c <- drop (max 0 (count - 128)) result.cmCalls]
        ]
    -- Correction is safe only if every submitted call returned a known
    -- pre-effect outcome (including no submissions). Missing receipts may hide
    -- an interrupted effect, so compare counts before inspecting outcomes.
    beforeEffects = count == result.cmSubmittedCalls && all ((`elem` ["rejected", "failed-before-effect"]) . (.ccOutcome)) result.cmCalls
    outcome = case result.cmExit of
      WasmCompleted -> ToolSucceeded summary
      WasmPaused -> ToolSucceeded summary
      WasmRejected detail -> ToolRejected (ToolFault "guest_limit" detail RetrySafe)
      _ | beforeEffects -> ToolFailedBeforeEffect (ToolFault "wasm_failed_before_effect" (TE.decodeUtf8 (wire summary)) RetrySafe)
      _ -> ToolOutcomeUnknown (ToolFault "wasm_interrupted" (TE.decodeUtf8 (wire summary)) RetryUnsafe)

boundedOutcome :: ToolOutcome -> Value
boundedOutcome outcome =
  let value = outcomeEnvelope outcome
      limit = 4 * 1024 * 1024
   in if LBS.length (LBS.take (limit + 1) (encode value)) <= limit
        then value
        else outcomeEnvelope (ToolOutcomeUnknown (ToolFault "result_too_large" "tool result exceeds 4 MiB; do not replay effects" RetryUnsafe))

resumeChunk :: [(Int, Value)] -> ([(Int, Value)], [(Int, Value)])
resumeChunk = go 2 []
  where
    go _ acc [] = (reverse acc, [])
    go bytes acc remaining@(entry : rest)
      | total > 16 * 1024 * 1024 = (reverse acc, remaining)
      | otherwise = go total (entry : acc) rest
      where
        total = bytes + LBS.length (encode entry) + if null acc then 0 else 1

wire :: Value -> ByteString
wire = LBS.toStrict . encode
