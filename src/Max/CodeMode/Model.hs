-- | Model submission adapter. The container is deliberately not a Tool runner:
-- its leaves enter the shared scheduling gate after this adapter dispatches it.
module Max.CodeMode.Model (codeModeSpecs, executionWaitSpecs, executeModelBatch) where

import Data.Aeson (Value (..), encode, object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Map.Strict (Map)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Effectful
import Effectful.Concurrent (Concurrent)
import Max.CodeMode.Execution (CodeModeResult (..), codeModeInvocation, runWasmProgram)
import Max.CodeMode.JavaScript (javaScriptLimits, javaScriptRuntimeVersion, runJavaScriptWith, workflowProgram)
import Max.Effects.Tools (Tools)
import Max.Execution.Tools
import Max.Skill.Workflow (ResolvedWorkflow (..), resolveWorkflow)
import Max.Tool.Bundles (SkillLoad)
import Max.Tool.Control (LoopControl (..))
import Max.Tool.Returns (withReturnType)
import Max.Tool.Types
import Max.Tools.Schema (stringParam, toolObject)

-- | run_code is always offered: the manual is optional reading, and a
-- composition should not cost a skill-loading poll first. Resume and cancel
-- appear only while this task has a program paused at an await.
codeModeSpecs :: Bool -> Bool -> [ToolSpec]
codeModeSpecs enabled paused =
  [ ToolSpec
      "run_code"
      (withReturnType "run_code" runCodeDescription)
      (toolObject [("code", stringParam "临时 async 函数体，最大 64 KiB；与 workflow/args 二选一"), ("workflow", stringParam "已加载工作流 skill/entry，固定为 use_skill 返回的版本"), ("args", object ["description" .= ("工作流输入，遵循已加载契约" :: Text)])] [])
  | enabled
  ]
    <> [ ToolSpec name (withReturnType name description) (toolObject [("run", stringParam "当前任务的暂停程序句柄，来自 run_code 的 run 字段")] ["run"])
       | enabled,
         paused,
         (name, description) <- [("run_code_resume", "从原 await 恢复暂停的程序；保留变量和已完成的调用，不重放副作用。"), ("run_code_cancel", "取消暂停程序及其仍在途的调用，返回已有回执；已发生的效果不回滚。")]
       ]

runCodeDescription :: Text
runCodeDescription =
  T.intercalate
    "\n"
    [ "用 JavaScript 组合本轮可见的工具，只把筛选后的 JSON 带回上下文。必须单独提交。",
      "适合：三个以上调用、有依赖的调用链、要先筛选的大结果、并行派多个子 agent 再汇总。一两个独立调用直接用原生工具，原生调用本身会并发。",
      "code 是 async 函数体，用 return 返回 JSON（最多 64 KiB）；可另传 args，代码里用 args 变量读取。已加载的工作流传 {workflow, args}。SDK：",
      "- await tools.<工具名>(args)：失败抛 ToolError；返回类型见各工具描述末尾「返回：」。",
      "- 并发用 Promise.all；依次 await 就是顺序执行；items.map(async x => b(await a(x))) 是流水线，每项做完一步就进下一步。",
      "- await agent({objective, profile, inputs, output_contract})：派子 agent 并等报告；报告在 result.text，给了 output_contract 时符合契约的 JSON 在 result.payload。",
      "- await max.raw(name, args)：返回 {outcome, value} 或 {outcome, error}，不抛错；扇出时一项失败不拖垮其他项。",
      "- await max.race(promises) 取第一个结果并取消其余；await max.sleep(ms) 用于超时。",
      "- 程序返回时会取消仍在途的调用，要做完的必须 await。没有网络、文件、时钟，这些都通过工具。",
      "不自动重试，已发生的工具效果不回滚。等待异步工具时收到 steering 会返回 {status:\"paused\", run}，再用 run_code_resume 或 run_code_cancel 处理。",
      "完整手册（翻上下文、保存的工作流、各项限额）：use_skill codemode。"
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
            Right (Left (source, args)) <- submission fields -> do
              result <- runJavaScriptWith session hooks catalog source args
              pure (ToolBatch [codeModeInvocation result] result.cmOverBudget)
        [request]
          | enabled,
            request.trName == "run_code",
            Object fields <- request.trArguments,
            Right (Right (reference, args)) <- submission fields ->
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
        _ -> pure (ToolBatch (map (const (reject "invalid_code_submission" (rejection requests))) requests) False)
  where
    -- {code} or {code, args}: ad-hoc code, args bound like a workflow's input.
    -- {workflow} or {workflow, args}: a loaded workflow, args defaulting to {}.
    submission fields
      | any (`notElem` ["code", "workflow", "args"]) keys = Left ("run_code 只认 code、workflow、args；多余字段：" <> T.intercalate "、" (filter (`notElem` ["code", "workflow", "args"]) keys))
      | otherwise = case (KeyMap.lookup "code" fields, KeyMap.lookup "workflow" fields) of
          (Just _, Just _) -> Left "code 和 workflow 二选一：临时代码传 code（可带 args），已加载的工作流传 workflow 和 args"
          (Just (String source), Nothing)
            | BS.length (TE.encodeUtf8 source) > 65536 -> Left "code 超过 64 KiB"
            | tooLarge -> Left "args 超过 64 KiB"
            | otherwise -> Right (Left (source, args))
          (Nothing, Just (String reference))
            | tooLarge -> Left "args 超过 64 KiB"
            | otherwise -> Right (Right (reference, fromMaybe (Object KeyMap.empty) args))
          (Nothing, Nothing) -> Left "需要 code（临时代码）或 workflow（已加载的工作流）"
          _ -> Left "code 和 workflow 必须是字符串"
      where
        keys = map Key.toText (KeyMap.keys fields)
        args = case KeyMap.lookup "args" fields of
          Just Null -> Nothing
          other -> other
        tooLarge = maybe False ((> 65536) . LBS.length . encode) args
    -- Say which rule failed: a generic message got the same mistake repeated.
    rejection batch
      | not enabled = "run_code 当前不可用。本轮未执行调用。"
      | length batch > 1 =
          "run_code 必须是这一轮唯一的调用，本轮 "
            <> T.pack (show (length batch))
            <> " 个调用都没有执行。其他工具写进 code 里用 tools.<名字>(…) 调用，或者分两轮调用。"
      | [request] <- batch,
        request.trName == "run_code",
        Object fields <- request.trArguments,
        Left reason <- submission fields =
          reason <> "。本轮未执行调用。"
      | otherwise = "run_code 的参数必须是对象：{code, args?} 或 {workflow, args?}。本轮未执行调用。"
    reject code detail = ToolInvocation (ToolRejected (ToolFault code detail RetrySafe)) ContinueLoop
