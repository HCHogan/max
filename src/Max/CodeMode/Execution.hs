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

import Control.Concurrent.STM (atomically, modifyTVar', newTVarIO, readTVarIO, writeTVar)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.Aeson (Value (..), eitherDecodeStrict', encode, object, toJSON, (.=))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (parseJSON, parseMaybe)
import Data.ByteString (ByteString)
import Data.ByteString.Base16 qualified as Base16
import Data.ByteString.Lazy qualified as LBS
import Data.Either (fromRight)
import Data.Foldable (toList)
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Effectful
import Effectful.Concurrent (Concurrent)
import Effectful.Exception (mask)
import Max.CodeMode.Wasm
import Max.Effects.Tools (Tools)
import Max.Execution.Tools
import Max.Execution.Types
import Max.Tool.Control (LoopControl (..), controlReply, mergeControls)
import Max.Tool.Types

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
    cmOverBudget :: !Bool
  }
  deriving stock (Show, Eq)

-- | Host-authored submission, not a decoder for model-provided module bytes.
data WasmProgram = WasmProgram
  { wpModule :: !ByteString,
    wpInput :: !(Maybe ByteString),
    wpEvidence :: !Value
  }

runWasmTools :: (Tools :> es, Concurrent :> es, IOE :> es) => ExecutionSession -> ExecutionHooks es -> [CatalogTool] -> WasmLimits -> ByteString -> Eff es CodeModeResult
runWasmTools session hooks catalog limits binary = runWasmProgram session hooks catalog limits (WasmProgram binary Nothing Null)

-- | Orchestration enters outside the leaf gate. Registering this as a leaf Tool
-- runner would recursively acquire that gate and deadlock.
runWasmProgram :: (Tools :> es, Concurrent :> es, IOE :> es) => ExecutionSession -> ExecutionHooks es -> [CatalogTool] -> WasmLimits -> WasmProgram -> Eff es CodeModeResult
runWasmProgram session hooks catalog limits program = do
  label <- freshExecutionLabel session "wasm"
  receipts <- liftIO (newTVarIO [])
  decisions <- liftIO (newTVarIO ContinueLoop)
  exhausted <- liftIO (newTVarIO False)
  submitted <- liftIO (newTVarIO 0)
  -- One bounded reply buffer, scoped to this run, replaced by the next dispatch.
  -- Paging this buffer never invokes a tool or reserves another leaf call.
  replyBuffer <- liftIO (newTVarIO Nothing)
  let start =
        JournalStart
          label
          "host:wasm/v1"
          1
          "max-wasm-abi-v1"
          (object ["sha256" .= digest program.wpModule, "input_sha256" .= fmap digest program.wpInput, "program" .= program.wpEvidence, "fuel" .= limits.wlFuel, "memory_bytes" .= limits.wlMemoryBytes, "timeout_micros" .= limits.wlTimeoutMicros, "host_calls" .= limits.wlHostCalls])
          (toJSON ([] :: [Value]))
          "unsafe"
      reply value = do
        liftIO . atomically $ writeTVar replyBuffer Nothing
        let bytes = LBS.take (4 * 1024 * 1024 + 1) (encode value)
        if LBS.length bytes > 4 * 1024 * 1024
          then pure . Just . wire $ object ["bridge_error" .= ("tool result exceeds 4 MiB; calls already ran, do not replay the program" :: Text)]
          else
            if LBS.length bytes <= 65536
              then pure (Just (LBS.toStrict bytes))
              else do
                ref <- freshExecutionLabel session (label <> "/result")
                let body = TE.decodeUtf8 (LBS.toStrict bytes)
                liftIO . atomically $ writeTVar replyBuffer (Just (ref, body))
                pure . Just . wire $ object ["result_ref" .= ref]
      dispatch bytes = case parseRequest bytes of
        Left detail -> pure . Just . wire $ outcomeEnvelope (ToolRejected (ToolFault "invalid_guest_request" detail RetrySafe))
        Right (ReadResult ref offset) -> do
          buffered <- liftIO (readTVarIO replyBuffer)
          pure . Just . wire $ case buffered of
            Just (current, body)
              | current == ref && offset >= 0 && offset <= T.length body ->
                  let chunk = T.take 8000 (T.drop offset body)
                      next = offset + T.length chunk
                   in object ["chunk" .= chunk, "next" .= next, "done" .= (next == T.length body)]
            _ -> object ["bridge_error" .= ("result reference or offset is not valid in this run" :: Text)]
        Right (Invoke many calls) -> mask $ \restore -> do
          used <- liftIO (readTVarIO submitted)
          let refuse = outcomeEnvelope (ToolRejected (ToolFault "guest_call_limit" "program leaf call limit exceeded" RetrySafe))
          if used + length calls > limits.wlHostCalls
            then reply (if many then toJSON (map (const refuse) calls) else refuse)
            else invoke restore many calls
      invoke restore many calls = do
        requests <- traverse (\(name, args) -> (\call -> ToolRequest call name args) <$> freshExecutionLabel session (label <> "/call")) calls
        liftIO . atomically $ modifyTVar' submitted (+ length requests)
        batch <- restore (executeToolBatch session hooks catalog requests)
        liftIO . atomically $ do
          modifyTVar' receipts (reverse [CodeModeCall req.trCallId req.trName (outcomeName invocation.tiOutcome) | (req, invocation) <- zip requests batch.tbInvocations] <>)
          modifyTVar' decisions (\previous -> mergeControls (previous : map (.tiControl) batch.tbInvocations))
          modifyTVar' exhausted (|| batch.tbOverBudget)
        if any (isJust . controlReply . (.tiControl)) batch.tbInvocations
          then pure Nothing
          else case (many, batch.tbInvocations) of
            (False, [invocation]) -> reply (outcomeEnvelope invocation.tiOutcome)
            (True, invocations) -> reply (toJSON (map (outcomeEnvelope . (.tiOutcome)) invocations))
            _ -> error "executeToolBatch violated result cardinality"
  (result, _) <- withExecutionRecord hooks ExecutionCheckpoint start $ \_ -> do
    (exit, rawOutput) <- runWasmWithInput limits program.wpModule program.wpInput dispatch
    calls <- reverse <$> liftIO (readTVarIO receipts)
    control <- liftIO (readTVarIO decisions)
    overBudget <- liftIO (readTVarIO exhausted)
    submittedCalls <- liftIO (readTVarIO submitted)
    let parsed = traverse (eitherDecodeStrict' @Value) rawOutput
        finalExit
          | isJust (controlReply control) = WasmHostStopped
          | Left _ <- parsed = WasmTrapped "guest output is not JSON"
          | otherwise = exit
        result = CodeModeResult finalExit calls control (fromRight Nothing parsed) submittedCalls overBudget
    pure (result, codeModeInvocation result)
  pure result
  where
    digest = TE.decodeUtf8 . Base16.encode . SHA256.hash

codeModeInvocation :: CodeModeResult -> ToolInvocation
codeModeInvocation result = ToolInvocation outcome result.cmControl
  where
    count = length result.cmCalls
    summary =
      object
        [ "exit" .= T.pack (show result.cmExit),
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
      _ | beforeEffects -> ToolFailedBeforeEffect (ToolFault "wasm_failed_before_effect" (TE.decodeUtf8 (wire summary)) RetrySafe)
      _ -> ToolOutcomeUnknown (ToolFault "wasm_interrupted" (TE.decodeUtf8 (wire summary)) RetryUnsafe)

wire :: Value -> ByteString
wire = LBS.toStrict . encode

data GuestRequest = Invoke !Bool ![(Text, Value)] | ReadResult !Text !Int

-- No task IDs, call IDs, schemas or controls can be supplied through the ABI.
parseRequest :: ByteString -> Either Text GuestRequest
parseRequest bytes = case eitherDecodeStrict' bytes of
  Right value@(Object fields)
    | Just single <- parseCall value -> Right (Invoke False [single])
    | KeyMap.size fields == 1,
      Just (Array calls) <- KeyMap.lookup "calls" fields,
      not (null calls),
      length calls <= 32,
      Just parsed <- traverse parseCall (toList calls) ->
        Right (Invoke True parsed)
    | KeyMap.size fields == 2,
      Just (String ref) <- KeyMap.lookup "result_ref" fields,
      Just offset <- KeyMap.lookup "offset" fields >>= parseMaybe parseJSON ->
        Right (ReadResult ref offset)
  _ -> invalid
  where
    invalid = Left "expected {tool: string, args: object}, {calls: [1..32 requests]}, or {result_ref: string, offset: integer}"
    parseCall (Object fields)
      | KeyMap.size fields == 2,
        Just (String name) <- KeyMap.lookup "tool" fields,
        not (T.null name),
        T.length name <= 256,
        Just args@(Object _) <- KeyMap.lookup "args" fields =
          Just (name, args)
    parseCall _ = Nothing
