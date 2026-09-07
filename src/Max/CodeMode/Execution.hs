-- | Wasm adapter for the same host executor used by native model calls.
module Max.CodeMode.Execution
  ( CodeModeResult (..),
    CodeModeCall (..),
    runWasmTools,
  )
where

import Control.Concurrent.STM (atomically, modifyTVar', newTVarIO, readTVarIO)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.Aeson (Value (..), eitherDecodeStrict', encode, object, toJSON, (.=))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString.Base16 qualified as Base16
import Data.ByteString.Lazy qualified as LBS
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

-- | Bounded receipts; full results remain in the existing journal/artifact
-- store. The container does not duplicate all leaf results in memory or SQL.
data CodeModeCall = CodeModeCall
  { ccLabel :: !Text,
    ccTool :: !Text,
    ccOutcome :: !Text
  }
  deriving stock (Show, Eq)

data CodeModeResult = CodeModeResult
  { cmExit :: !WasmExit,
    cmCalls :: ![CodeModeCall],
    cmControl :: !LoopControl
  }
  deriving stock (Show, Eq)

-- | An orchestration entry, outside the leaf scheduling gate. Installing this
-- as a leaf Tool runner would recursively acquire that gate. A model-facing
-- container adapter must enter here before ordinary leaf dispatch.
runWasmTools :: (Tools :> es, Concurrent :> es, IOE :> es) => ExecutionSession -> ExecutionHooks es -> [CatalogTool] -> WasmLimits -> ByteString -> Eff es CodeModeResult
runWasmTools session hooks catalog limits binary = do
  label <- freshExecutionLabel session "wasm"
  receipts <- liftIO (newTVarIO [])
  decisions <- liftIO (newTVarIO ContinueLoop)
  let start =
        JournalStart
          label
          "host:wasm/v1"
          1
          "max-wasm-abi-v1"
          (object ["sha256" .= TE.decodeUtf8 (Base16.encode (SHA256.hash binary)), "fuel" .= limits.wlFuel, "memory_bytes" .= limits.wlMemoryBytes, "timeout_micros" .= limits.wlTimeoutMicros, "host_calls" .= limits.wlHostCalls])
          (toJSON ([] :: [Value]))
          "unsafe"
      dispatch bytes = case parseRequest bytes of
        Left detail ->
          pure . Just . LBS.toStrict . encode $
            outcomeEnvelope (ToolRejected (ToolFault "invalid_guest_request" detail RetrySafe))
        Right (name, args) -> mask $ \restore -> do
          call <- freshExecutionLabel session (label <> "/call")
          batch <- restore (executeToolBatch session hooks catalog [ToolRequest call name args])
          case batch.tbInvocations of
            [invocation] -> do
              liftIO . atomically $ do
                modifyTVar' receipts (CodeModeCall call name (outcomeName invocation.tiOutcome) :)
                modifyTVar' decisions (\previous -> mergeControls [previous, invocation.tiControl])
              pure $
                if isJust (controlReply invocation.tiControl)
                  then Nothing
                  else Just (LBS.toStrict (encode (outcomeEnvelope invocation.tiOutcome)))
            _ -> error "executeToolBatch violated result cardinality"
  (result, _) <- withExecutionRecord hooks ExecutionCheckpoint start $ \_ -> do
    exit <- runWasm limits binary dispatch
    calls <- reverse <$> liftIO (readTVarIO receipts)
    control <- liftIO (readTVarIO decisions)
    let finalExit = if isJust (controlReply control) then WasmHostStopped else exit
        summary = object ["exit" .= T.pack (show finalExit), "calls" .= [object ["call" .= c.ccLabel, "tool" .= c.ccTool, "outcome" .= c.ccOutcome] | c <- calls]]
        -- A failed container is never replay-safe: a leaf may have committed.
        -- The exact effect outcomes remain authoritative on the leaf rows.
        outcome = case finalExit of
          WasmCompleted -> ToolSucceeded summary
          WasmHostStopped -> ToolSucceeded summary
          _ -> ToolOutcomeUnknown (ToolFault "wasm_interrupted" (T.pack (show finalExit)) RetryUnsafe)
    pure (CodeModeResult finalExit calls control, ToolInvocation outcome control)
  pure result

-- No task IDs, call IDs, schemas or controls can be supplied through the ABI.
parseRequest :: ByteString -> Either Text (Text, Value)
parseRequest bytes = case eitherDecodeStrict' bytes of
  Right (Object fields)
    | KeyMap.size fields == 2,
      Just (String name) <- KeyMap.lookup "tool" fields,
      not (T.null name),
      T.length name <= 256,
      Just args@(Object _) <- KeyMap.lookup "args" fields ->
        Right (name, args)
  _ -> Left "expected exactly {tool: nonempty string, args: object}"
