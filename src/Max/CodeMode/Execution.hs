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
import Control.Concurrent.STM (atomically, modifyTVar', newTVarIO, readTVarIO, writeTVar)
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
import Effectful.Concurrent.Async (async, cancel)
import Effectful.Exception (bracket, finally, mask, throwIO)
import Max.CodeMode.Wasm
import Max.Effects.Tools (Tools)
import Max.Execution.Tools
import Max.Execution.Types
import Max.Skill.Contract (Contract, validateValue)
import Max.Tool.Control
  ( LoopControl (..),
    mergeControls,
  )
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
    cmWorkflow :: !(Maybe Value)
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
runWasmProgram session hooks catalog limits program = bracket hooks.ehAcquireGuest (mapM_ liftIO) $ \case
  Nothing -> pure (CodeModeResult (WasmRejected "live guest limit exceeded; retry later or use native tools") [] ContinueLoop Nothing 0 False "" program.wpWorkflow)
  Just _ -> runAdmittedProgram session hooks catalog limits program

runAdmittedProgram :: (Tools :> es, Concurrent :> es, IOE :> es) => ExecutionSession -> ExecutionHooks es -> [CatalogTool] -> WasmLimits -> WasmProgram -> Eff es CodeModeResult
runAdmittedProgram session hooks catalog limits program = do
  label <- freshExecutionLabel session "wasm"
  receipts <- liftIO (newTVarIO [])
  decisions <- liftIO (newTVarIO ContinueLoop)
  exhausted <- liftIO (newTVarIO False)
  submitted <- liftIO (newTVarIO 0)
  workers <- liftIO (newTVarIO Map.empty)
  seen <- liftIO (newTVarIO Set.empty)
  buffered <- liftIO (newTVarIO [])
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
      cleanup = liftIO (readTVarIO workers) >>= mapM_ (void . stop) . Map.keys
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
              liftIO . atomically $ modifyTVar' seen (<> Set.fromList ids)
              forM_ calls launch
              -- Cancellation completes the promise too: a program may catch it.
              cancelledResults <- catMaybes <$> traverse stop (Set.toList (Set.fromList cancellations))
              pending <- liftIO (readTVarIO workers)
              previous <- liftIO (readTVarIO buffered)
              if Map.null pending && null cancelledResults && null previous
                then pure (WasmTrapped "guest waiting without in-flight calls", Nothing)
                else do
                  ready <-
                    if null cancelledResults && null previous
                      then liftIO . atomically $ do
                        _ <- Async.waitAnyCatchSTM (map (snd . snd) (Map.toList pending))
                        forM (Map.toList pending) $ \(ident, (request, worker)) -> (ident,request,) <$> Async.pollSTM worker
                      else pure []
                  let completed = [(ident, request, outcome) | (ident, request, Just outcome) <- ready]
                  outcomes <- forM completed $ \(ident, request, outcome) -> do
                    invocation <- either throwIO pure outcome
                    record request invocation
                    liftIO . atomically $ modifyTVar' workers (Map.delete ident)
                    pure (ident, boundedOutcome invocation.tiOutcome)
                  -- Deliver every ready completion that fits; retain the rest
                  -- until the next step without holding unrelated calls back.
                  let (chunk, rest) = resumeChunk (previous <> cancelledResults <> outcomes)
                  liftIO . atomically $ writeTVar buffered rest
                  if any (feedbackPending . snd) outcomes
                    then pure (WasmHostStopped, Just (toJSON (map snd outcomes)))
                    else do
                      step <- liftIO (resumeGuest guest chunk)
                      drive guest step

  (result, _) <- withExecutionRecord hooks ExecutionCheckpoint start $ \row -> do
    (exit, output) <- withGuest limits program.wpModule (fromMaybe "" program.wpInput) (\guest initial -> drive guest initial `finally` cleanup)
    calls <- reverse <$> liftIO (readTVarIO receipts)
    control <- liftIO (readTVarIO decisions)
    overBudget <- liftIO (readTVarIO exhausted)
    submittedCalls <- liftIO (readTVarIO submitted)
    let finalExit = case (exit, program.wpOutputContract) of
          (WasmCompleted, Just contract) | Left err <- validateValue contract (fromMaybe Null output) -> WasmTrapped ("workflow output contract: " <> err)
          _ -> exit
        result = CodeModeResult finalExit calls control output submittedCalls overBudget (maybe label (\entry -> resultHandleText entry.jeTurn.atrTurnOrdinal entry.jeExecutionOrdinal) row) program.wpWorkflow
    pure (result, codeModeInvocation result)
  pure result
  where
    digest = TE.decodeUtf8 . Base16.encode . SHA256.hash
    isBudget (ToolRejected fault) = fault.tfCode == "call_budget_exhausted"
    isBudget _ = False
    feedbackPending (Object fields) = case KeyMap.lookup "value" fields of
      Just (Object value) -> KeyMap.lookup "feedback_pending" value == Just (Bool True)
      _ -> False
    feedbackPending _ = False

codeModeInvocation :: CodeModeResult -> ToolInvocation
codeModeInvocation result = ToolInvocation outcome result.cmControl
  where
    count = length result.cmCalls
    summary =
      object
        [ "run_ref" .= result.cmRunRef,
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
      WasmHostStopped -> ToolSucceeded summary
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
