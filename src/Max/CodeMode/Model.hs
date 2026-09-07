-- | Model submission adapter. The container is deliberately not a Tool runner:
-- its leaves enter the shared scheduling gate after this adapter dispatches it.
module Max.CodeMode.Model (codeModeSpecs, executeModelBatch) where

import Data.Aeson (Value (..))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as BS
import Data.Text.Encoding qualified as TE
import Effectful
import Effectful.Concurrent (Concurrent)
import Max.CodeMode.Execution (CodeModeResult (..), codeModeInvocation)
import Max.CodeMode.JavaScript (runJavaScript)
import Max.Effects.Tools (Tools)
import Max.Execution.Tools
import Max.Tool.Control (LoopControl (..))
import Max.Tool.Types
import Max.Tools.Schema (stringParam, toolObject)

codeModeSpecs :: Bool -> [ToolSpec]
codeModeSpecs enabled =
  [ ToolSpec
      "run_code"
      "用 codemode 技能的 JavaScript SDK 组合当前工具并返回筛选后的 JSON。必须单独提交；同一程序不自动重试，已发生的工具效果不会回滚。"
      (toolObject [("code", stringParam "async 函数体；通过 tools 调用当前工具，return JSON 结果；最大 64 KiB")] ["code"])
  | enabled
  ]

executeModelBatch :: (Tools :> es, Concurrent :> es, IOE :> es) => Bool -> ExecutionSession -> ExecutionHooks es -> [CatalogTool] -> [ToolRequest] -> Eff es ToolBatch
executeModelBatch enabled session hooks catalog requests
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
        _ -> pure (ToolBatch (map (const rejection) requests) False)
  where
    rejection =
      ToolInvocation
        ( ToolRejected
            ( ToolFault
                "invalid_code_submission"
                "先加载 codemode 技能；run_code 必须作为这一轮唯一调用，参数只能是 code 字符串（最多 64 KiB）。本轮未执行任何调用。"
                RetrySafe
            )
        )
        ContinueLoop
