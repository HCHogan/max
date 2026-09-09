-- | Model submission adapter. The container is deliberately not a Tool runner:
-- its leaves enter the shared scheduling gate after this adapter dispatches it.
module Max.CodeMode.Model (codeModeSpecs, executeModelBatch) where

import Data.Aeson (Value (..), encode, object, (.=))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Map.Strict (Map)
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import Effectful
import Effectful.Concurrent (Concurrent)
import Max.CodeMode.Execution (CodeModeResult (..), codeModeInvocation, runWasmProgram)
import Max.CodeMode.JavaScript (javaScriptLimits, runJavaScript, workflowProgram)
import Max.Effects.Tools (Tools)
import Max.Execution.Tools
import Max.Skill.Workflow (ResolvedWorkflow (..), resolveWorkflow)
import Max.Tool.Bundles (SkillLoad)
import Max.Tool.Control (LoopControl (..))
import Max.Tool.Types
import Max.Tools.Schema (stringParam, toolObject)

codeModeSpecs :: Bool -> [ToolSpec]
codeModeSpecs enabled =
  [ ToolSpec
      "run_code"
      "用 codemode 技能的 JavaScript SDK 组合当前工具并返回筛选后的 JSON。必须单独提交；同一程序不自动重试，已发生的工具效果不会回滚。"
      (toolObject [("code", stringParam "临时 async 函数体，最大 64 KiB；与 workflow/args 二选一"), ("workflow", stringParam "已加载工作流 skill/entry，固定为 use_skill 返回的版本"), ("args", object ["description" .= ("工作流输入，遵循已加载契约" :: Text)])] [])
  | enabled
  ]

executeModelBatch :: (Tools :> es, Concurrent :> es, IOE :> es) => Bool -> Map Text SkillLoad -> ExecutionSession -> ExecutionHooks es -> [CatalogTool] -> [ToolRequest] -> Eff es ToolBatch
executeModelBatch enabled loaded session hooks catalog requests
  | not (any ((== "run_code") . (.trName)) requests) = executeToolBatch session hooks catalog requests
  | otherwise = do
      hooks.ehCheck
      case requests of
        [request]
          | enabled,
            Object fields <- request.trArguments,
            KeyMap.size fields == 1,
            Just (String source) <- KeyMap.lookup "code" fields,
            BS.length (TE.encodeUtf8 source) <= 65536 -> do
              result <- runJavaScript session hooks catalog source
              pure (ToolBatch [codeModeInvocation result] result.cmOverBudget)
        [request]
          | enabled,
            Object fields <- request.trArguments,
            KeyMap.size fields == 2,
            Just (String reference) <- KeyMap.lookup "workflow" fields,
            Just args <- KeyMap.lookup "args" fields,
            LBS.length (encode args) <= 65536 ->
              case resolveWorkflow loaded catalog reference args of
                Left detail -> pure (ToolBatch [reject "invalid_workflow_submission" detail] False)
                Right resolved -> do
                  result <-
                    runWasmProgram
                      session
                      hooks
                      resolved.rwCatalog
                      javaScriptLimits
                      (workflowProgram resolved.rwCatalog reference resolved.rwVersion resolved.rwWorkflow args)
                  pure (ToolBatch [codeModeInvocation result] result.cmOverBudget)
        _ -> pure (ToolBatch (map (const rejection) requests) False)
  where
    rejection = reject "invalid_code_submission" "先加载 codemode；run_code 必须单独提交 {code} 或 {workflow, args}（源码/输入最多 64 KiB）。本轮未执行调用。"
    reject code detail = ToolInvocation (ToolRejected (ToolFault code detail RetrySafe)) ContinueLoop
