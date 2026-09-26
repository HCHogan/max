-- | Model submission adapter. The container is deliberately not a Tool runner:
-- its leaves enter the shared scheduling gate after this adapter dispatches it.
module Max.CodeMode.Model (codeModeSpecs, executionWaitSpecs, executeModelBatch) where

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
import Max.CodeMode.JavaScript (javaScriptLimits, javaScriptRuntimeVersion, runJavaScript, workflowProgram)
import Max.Effects.Tools (Tools)
import Max.Execution.Tools
import Max.Skill.Workflow (ResolvedWorkflow (..), resolveWorkflow)
import Max.Tool.Bundles (SkillLoad)
import Max.Tool.Control (LoopControl (..))
import Max.Tool.Returns (withReturnType)
import Max.Tool.Types
import Max.Tools.Schema (stringParam, toolObject)

codeModeSpecs :: Bool -> [ToolSpec]
codeModeSpecs enabled =
  [ ToolSpec
      "run_code"
      (withReturnType "run_code" "用 codemode 技能的 JavaScript SDK 组合当前工具并返回筛选后的 JSON。必须单独提交；同一程序不自动重试，已发生的工具效果不会回滚。")
      (toolObject [("code", stringParam "临时 async 函数体，最大 64 KiB；与 workflow/args 二选一"), ("workflow", stringParam "已加载工作流 skill/entry，固定为 use_skill 返回的版本"), ("args", object ["description" .= ("工作流输入，遵循已加载契约" :: Text)])] [])
  | enabled
  ]
    <> [ ToolSpec name (withReturnType name description) (toolObject [("run", stringParam "当前任务的暂停程序句柄，来自 run_code 的 run 字段")] ["run"])
       | enabled,
         (name, description) <- [("run_code_resume", "从原 await 恢复暂停的程序；保留变量和已完成的调用，不重放副作用。"), ("run_code_cancel", "取消暂停程序及其仍在途的调用，返回已有回执；已发生的效果不回滚。")]
       ]

executionWaitSpecs :: Bool -> [ToolSpec]
executionWaitSpecs available =
  [ToolSpec "execution_wait" (withReturnType "execution_wait" "等待当前任务中被 steering 中断的异步调用；使用返回的 result 句柄，不重跑调用。") (toolObject [("result", stringParam "异步调用的 result 句柄")] ["result"]) | available]

executeModelBatch :: (Tools :> es, Concurrent :> es, IOE :> es) => Bool -> Map Text SkillLoad -> ExecutionSession -> ExecutionHooks es -> [CatalogTool] -> [ToolRequest] -> Eff es ToolBatch
executeModelBatch enabled loaded session hooks catalog requests
  | [request] <- requests,
    request.trName == "execution_wait",
    Object fields <- request.trArguments,
    KeyMap.size fields == 1,
    Just (String ref) <- KeyMap.lookup "result" fields = do
      hooks.ehCheck
      invocation <- waitExecution session hooks ref
      pure (ToolBatch [invocation] False)
  | [request] <- requests,
    enabled,
    request.trName `elem` ["run_code_resume", "run_code_cancel"],
    Object fields <- request.trArguments,
    KeyMap.size fields == 1,
    Just (String ref) <- KeyMap.lookup "run" fields = do
      hooks.ehCheck
      invocation <- controlProgram session (request.trName == "run_code_resume") ref
      pure (ToolBatch [invocation] False)
  | not (any ((`elem` ["run_code", "run_code_resume", "run_code_cancel", "execution_wait"]) . (.trName)) requests) = executeToolBatch session hooks catalog requests
  | otherwise = do
      hooks.ehCheck
      case requests of
        [request]
          | enabled,
            request.trName == "run_code",
            Object fields <- request.trArguments,
            KeyMap.size fields == 1,
            Just (String source) <- KeyMap.lookup "code" fields,
            BS.length (TE.encodeUtf8 source) <= 65536 -> do
              result <- runJavaScript session hooks catalog source
              pure (ToolBatch [codeModeInvocation result] result.cmOverBudget)
        [request]
          | enabled,
            request.trName == "run_code",
            Object fields <- request.trArguments,
            KeyMap.size fields == 2,
            Just (String reference) <- KeyMap.lookup "workflow" fields,
            Just args <- KeyMap.lookup "args" fields,
            LBS.length (encode args) <= 65536 ->
              case resolveWorkflow javaScriptRuntimeVersion loaded catalog reference args of
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
