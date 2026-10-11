-- | A separate bounded, effect-free execution mode using the embedded codemode
-- guest. No ExecutionSession, model, tool authority or host futures are created.
module Max.Hook.Runtime (runHook, validateSource, warmHookRuntime) where

import Control.Monad (void)
import Data.Aeson (Value (..), object, (.=))
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Effectful
import GHC.Clock (getMonotonicTimeNSec)
import Max.CodeMode.Execution (WasmProgram (..))
import Max.CodeMode.JavaScript (javaScriptProgramWith)
import Max.CodeMode.Wasm
import Max.Hook.Types

hookLimits :: WasmLimits
hookLimits = defaultWasmLimits {wlFuel = 10000000, wlMemoryBytes = 64 * 1024 * 1024, wlTimeoutMicros = 1000000, wlModuleBytes = 4 * 1024 * 1024, wlHostCalls = 1}

evaluate :: (IOE :> es) => Text -> Value -> Eff es (Either Text Value)
evaluate = evaluateWith hookLimits

evaluateWith :: (IOE :> es) => WasmLimits -> Text -> Value -> Eff es (Either Text Value)
evaluateWith limits code args = do
  let program = javaScriptProgramWith [] [] code (Just args)
  withCachedGuest limits program.wpModule (fromMaybe "" program.wpInput) $ \_ -> \case
    GuestDone value -> pure (Right value)
    GuestCalls {} -> pure (Left "hooks cannot call tools, sleep or await host effects")
    GuestTrap failure -> pure (Left (T.take 512 (T.filter (/= '\0') (T.pack (show failure)))))

-- Compile trusted interpreter code before opening live ingress. Cold compiler
-- cost must not consume the budget of the first user's message after restart.
warmHookRuntime :: IO ()
warmHookRuntime = do
  result <- runEff (evaluateWith hookLimits {wlTimeoutMicros = 30000000} "return true;" Null)
  either (ioError . userError . T.unpack) (const (pure ())) result

-- Compile the function body without executing it. The constructor receives
-- source as data, so source cannot escape the validation wrapper.
validateSource :: (IOE :> es) => Text -> Eff es (Either Text ())
validateSource code = void <$> evaluate "const AsyncFunction = (async()=>{}).constructor; new AsyncFunction('args', '\"use strict\";\\n' + args.source); return true;" (object ["source" .= code])

runHook :: (IOE :> es) => HookDefinition -> Value -> Eff es HookResult
runHook definition event = do
  start <- liftIO getMonotonicTimeNSec
  value <- evaluate definition.source (object ["event" .= event, "config" .= definition.config])
  end <- liftIO getMonotonicTimeNSec
  let result = either (\err -> HookResult "error" (Just err) 0) id (value >>= parseDecision)
  pure result {elapsedMs = fromIntegral (end - start) / 1000000}
