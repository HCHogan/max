{-# LANGUAGE TemplateHaskell #-}

-- | Fixed JavaScript guest and SDK. No model protocol or domain tool runners.
module Max.CodeMode.JavaScript
  ( javaScriptLimits,
    javaScriptRuntimeVersion,
    runJavaScript,
    javaScriptProgram,
    workflowProgram,
  )
where

import Crypto.Hash.SHA256 qualified as SHA256
import Data.Aeson (Value, encode, object, (.=))
import Data.ByteString (ByteString)
import Data.ByteString.Base16 qualified as Base16
import Data.ByteString.Lazy qualified as LBS
import Data.FileEmbed (embedFile)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import Effectful
import Effectful.Concurrent (Concurrent)
import Language.Haskell.TH.Syntax (qAddDependentFile, runIO)
import Max.CodeMode.Execution
import Max.CodeMode.Wasm (WasmLimits (..), defaultWasmLimits)
import Max.Effects.Tools (Tools)
import Max.Execution.Tools (ExecutionHooks, ExecutionSession)
import Max.Skill.Package (Workflow (..))
import Max.Task.Policy (taskDeadlineSeconds)
import Max.Tool.Types
import System.Environment (lookupEnv)

-- Build-time dependency only. No runtime path lookup or executable discovery.
-- Changing the guest sources re-runs this splice after the Nix artifact rebuild.
javaScriptRuntime :: ByteString
javaScriptRuntime =
  $( do
       qAddDependentFile "codemode/quickjs.c"
       qAddDependentFile "nix/codemode-js.nix"
       path <- runIO (fromMaybe ".generated/quickjs.wasm" <$> lookupEnv "MAX_CODEMODE_JS_WASM")
       embedFile path
   )

javaScriptSdk :: ByteString
javaScriptSdk = $(embedFile "codemode/sdk.js")

-- Validation evidence changes automatically when the embedded guest or SDK changes.
javaScriptRuntimeVersion :: Text
javaScriptRuntimeVersion = TE.decodeUtf8 (Base16.encode (SHA256.hash (javaScriptRuntime <> javaScriptSdk)))

javaScriptLimits :: WasmLimits
javaScriptLimits =
  defaultWasmLimits
    { wlFuel = 1000000000,
      wlTimeoutMicros = taskDeadlineSeconds * 1000000,
      wlModuleBytes = 4 * 1024 * 1024,
      wlHostCalls = 1024
    }

javaScriptProgram :: [CatalogTool] -> Text -> WasmProgram
javaScriptProgram catalog source = programWithInput catalog source Nothing Nothing Nothing

workflowProgram :: [CatalogTool] -> Text -> Text -> Workflow -> Value -> WasmProgram
workflowProgram catalog reference version workflow args =
  programWithInput
    catalog
    workflow.wfSource
    (Just args)
    (Just workflow.wfOutput)
    (Just (object ["reference" .= reference, "version" .= version, "args" .= args]))

programWithInput :: [CatalogTool] -> Text -> Maybe Value -> Maybe Value -> Maybe Value -> WasmProgram
programWithInput catalog source args contract workflow =
  WasmProgram
    javaScriptRuntime
    (Just input)
    ( object
        [ "language" .= ("javascript" :: Text),
          "runtime" .= ("quickjs-ng-0.16.2" :: Text),
          "source" .= source,
          "workflow" .= workflow,
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
    input = javaScriptSdk <> "(__maxCall," <> LBS.toStrict (encode names) <> ");\n(async (" <> parameter <> ") => {\n\"use strict\";\n" <> TE.encodeUtf8 source <> "\n})" <> suffix

runJavaScript :: (Tools :> es, Concurrent :> es, IOE :> es) => ExecutionSession -> ExecutionHooks es -> [CatalogTool] -> Text -> Eff es CodeModeResult
runJavaScript session hooks catalog source = runWasmProgram session hooks catalog javaScriptLimits (javaScriptProgram catalog source)
