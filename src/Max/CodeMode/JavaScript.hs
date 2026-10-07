{-# LANGUAGE TemplateHaskell #-}

-- | Fixed JavaScript guest and SDK. No model protocol or domain tool runners.
module Max.CodeMode.JavaScript
  ( javaScriptLimits,
    javaScriptRuntimeVersion,
    runJavaScript,
    runJavaScriptWith,
    javaScriptProgram,
    javaScriptProgramWith,
    workflowProgram,
  )
where

import Crypto.Hash.SHA256 qualified as SHA256
import Data.Aeson (Value (..), encode, object, (.=))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as Base16
import Data.ByteString.Lazy qualified as LBS
import Data.FileEmbed (embedFile)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Effectful
import Effectful.Concurrent (Concurrent)
import Language.Haskell.TH.Syntax (qAddDependentFile, runIO)
import Max.CodeMode.Abi (checkGuestAbi)
import Max.CodeMode.Execution
import Max.CodeMode.Wasm (WasmLimits (..), defaultWasmLimits)
import Max.Effects.Tools (Tools)
import Max.Execution.Tools (ExecutionHooks, ExecutionSession)
import Max.Skill.Contract (Contract)
import Max.Skill.Package (Workflow (..))
import Max.Tool.Types
import System.Environment (lookupEnv)

-- Build-time dependency only. No runtime path lookup or executable discovery.
-- Changing the guest sources re-runs this splice after the Nix artifact rebuild.
-- Set MAX_CODEMODE_JS_WASM when compiling this module: changing the environment
-- only when running tests cannot replace guest bytes already embedded here.
-- A guest whose imports differ from the host ABI fails the build: a dev shell
-- evaluated before codemode/quickjs.c changed points at a stale guest, which
-- would otherwise compile and trap on every program.
javaScriptRuntime :: ByteString
javaScriptRuntime =
  $( do
       qAddDependentFile "codemode/quickjs.c"
       qAddDependentFile "nix/codemode-js.nix"
       path <- runIO (fromMaybe ".generated/quickjs.wasm" <$> lookupEnv "MAX_CODEMODE_JS_WASM")
       guest <- runIO (BS.readFile path)
       case checkGuestAbi guest of
         Left problem ->
           fail
             ( "code-mode guest " <> path <> " does not match the host ABI (" <> T.unpack problem
                 <> "). It was built from an older codemode/quickjs.c: re-enter the dev shell"
                 <> " (direnv reload) or set MAX_CODEMODE_JS_WASM to $(nix build .#codemode-js --print-out-paths)/quickjs.wasm."
             )
         Right () -> embedFile path
   )

javaScriptSdk :: ByteString
javaScriptSdk = $(embedFile "codemode/sdk.js")

-- Validation evidence changes automatically when the embedded guest or SDK changes.
javaScriptRuntimeVersion :: Text
javaScriptRuntimeVersion = TE.decodeUtf8 (Base16.encode (SHA256.hash (javaScriptRuntime <> javaScriptSdk)))

javaScriptLimits :: WasmLimits
javaScriptLimits =
  defaultWasmLimits
    { wlFuel = 10000000000,
      wlTimeoutMicros = 60 * 1000000,
      wlMemoryBytes = 256 * 1024 * 1024,
      wlModuleBytes = 4 * 1024 * 1024,
      wlHostCalls = 4096
    }

javaScriptProgram :: [CatalogTool] -> Text -> WasmProgram
javaScriptProgram catalog source = programWithInput catalog [] source Nothing Nothing Nothing

-- | Ad-hoc code with an @args@ value, bound like a workflow's input; the
-- journal evidence records it so a resumed turn can read what was passed.
javaScriptProgramWith :: [CatalogTool] -> [(Text, Workflow)] -> Text -> Maybe Value -> WasmProgram
javaScriptProgramWith catalog callable source = \case
  Nothing -> programWithInput catalog callable source Nothing Nothing Nothing
  Just args ->
    let program = programWithInput catalog callable source (Just args) Nothing Nothing
     in program {wpEvidence = case program.wpEvidence of
                   Object fields -> Object (KeyMap.insert "args" args fields)
                   other -> other}

workflowProgram :: [CatalogTool] -> [(Text, Workflow)] -> Text -> Text -> Workflow -> Value -> WasmProgram
workflowProgram catalog callable reference version workflow args =
  programWithInput
    catalog
    callable
    workflow.wfSource
    (Just args)
    (Just workflow.wfOutput)
    (Just (object ["reference" .= reference, "version" .= version, "args" .= args]))

programWithInput :: [CatalogTool] -> [(Text, Workflow)] -> Text -> Maybe Value -> Maybe Contract -> Maybe Value -> WasmProgram
programWithInput catalog callable source args contract workflow =
  WasmProgram
    javaScriptRuntime
    (Just input)
    ( object
        [ "language" .= ("javascript" :: Text),
          "runtime" .= ("quickjs-ng-0.16.2" :: Text),
          "source" .= source,
          "workflow" .= workflow,
          "callable_workflows" .= map fst callable,
          "catalog" .= [object ["tool" .= entry.ctDefinition.tdRef.unToolRef, "schema_hash" .= entry.ctSchemaHash.unSchemaHash] | entry <- catalog]
        ]
    )
    contract
    workflow
  where
    names = [entry.ctDefinition.tdRef.unToolRef | entry <- catalog, entry.ctDefinition.tdRef /= ToolRef "run_code"]
    argument = maybe "" (LBS.toStrict . encode . TE.decodeUtf8 . LBS.toStrict . encode) args
    suffix = maybe "()" (const ("(JSON.parse(" <> argument <> "))")) args
    parameter = maybe "" (const "args") args
    -- Each callable workflow becomes an async function of its args; sealing
    -- before the body keeps the program from adding or replacing any.
    registrations =
      mconcat
        [ "__maxDefineWorkflow(" <> LBS.toStrict (encode reference) <> ", async (args) => {\n\"use strict\";\n" <> TE.encodeUtf8 w.wfSource <> "\n});\n"
        | (reference, w) <- callable
        ]
        <> "__maxSealWorkflows();\n"
    input = javaScriptSdk <> "(" <> LBS.toStrict (encode names) <> ");\n" <> registrations <> "(async (" <> parameter <> ") => {\n\"use strict\";\n" <> TE.encodeUtf8 source <> "\n})" <> suffix

runJavaScript :: (Tools :> es, Concurrent :> es, IOE :> es) => ExecutionSession -> ExecutionHooks es -> [CatalogTool] -> Text -> Eff es CodeModeResult
runJavaScript session hooks catalog source = runJavaScriptWith session hooks catalog [] source Nothing

runJavaScriptWith :: (Tools :> es, Concurrent :> es, IOE :> es) => ExecutionSession -> ExecutionHooks es -> [CatalogTool] -> [(Text, Workflow)] -> Text -> Maybe Value -> Eff es CodeModeResult
runJavaScriptWith session hooks catalog callable source args = runWasmProgram session hooks catalog javaScriptLimits (javaScriptProgramWith catalog callable source args)
