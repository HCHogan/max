module Max.Tools.Task (taskToolsFor) where

import Data.Aeson
import Data.Aeson.Types (parseEither)
import Data.ByteString.Lazy qualified as LBS
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Effectful
import Max.Effects.TaskControl
  ( StartOutcome (..),
    TaskControl,
    TaskRequest (..),
    controlTask,
    startTask,
    waitTasks,
  )
import Max.Effects.TaskExecution
  ( TaskExecution,
    reportProgress,
  )
import Max.Effects.TaskQuery (TaskQuery, listTasks, readTask)
import Max.Effects.Tools (Tool (..), ToolRunner (..), legacyTool)
import Max.Effects.TurnQuery (TurnQuery, resolveTurnResult)
import Max.Task.State qualified as State
import Max.Task.Types
import Max.ToolContext
import Max.Tools.Schema
  ( boolParam,
    enumParam,
    noArguments,
    stringArrayParam,
    stringParam,
    toolObject,
  )
import Max.Turn.Types (turnOutputAgentTurn)

taskToolsFor :: (TaskQuery :> es, TaskControl :> es, TaskExecution :> es, TurnQuery :> es) => ToolContext -> [Tool es]
taskToolsFor context =
  [ startTool,
    legacyTool "agent_list" "列出本会话当前进程里的子 agent；完成后会主动通知，不需要轮询。" noArguments (\_ -> Right . toJSON <$> listTasks),
    legacyTool
      "agent_status"
      "查看指定子 agent 的状态、证据、预算和未处理事件。"
      handleSchema
      (parseArgs (withObject "agent_status" (.: "agent")) $ \handle -> withHandle handle (fmap (maybe (Left "agent not found in this conversation") (Right . toJSON)) . readTask))
  ]
    <> [controlTool operation | operation <- [State.Steer, State.Replace, State.Cancel], not background || operation == State.Steer]
    <> (if background then [waitTool, progressTool] else [])
  where
    background = (toolCapabilities context).tcBackground
    durable = turnOutputAgentTurn <$> toolTurnOutputContext context
    handleSchema = toolObject [("agent", stringParam "agent# 标识；必须来自本会话。")] ["agent"]
    withHandle handle action = maybe (pure (Left "无效 agent# 标识")) action (parseTaskHandle handle)
    parseArgs parser action raw = case parseEither parser raw of
      Left detail -> pure (Left (T.pack detail))
      Right args -> action args
    startTool =
      Tool
        { toolName = "agent",
          toolDescription = "派一个子 agent 在后台工作。默认启动后立即返回 agent#：适合长研究、浏览器、sandbox 或 SSH 运维，简短告知用户已启动即可结束本轮，不要等待或轮询；它结束后报告交回前台，由你转述给发起者。wait=true 时在本次调用里等报告回来，返回已结束的子 agent（result.text，契约结果在 result.payload）：用于本轮就要用结果的子问题，多个独立子问题一起提交会并发执行；等待的子 agent 是叶子，不能再用 run_code。子 agent 不会直接向群里发言。profile 只收窄现有权限。每棵 agent 树共享 2000 次工具预留、2000 次模型请求和六小时截止时间，替换目标不重置；预算用完时各 agent 不再调用工具，直接写报告。token/cost 仅观测，不是硬额度。",
          toolSchema =
            toolObject
              [ ("objective", stringParam "自包含目标、约束和期望证据，不依赖整段聊天记录。"),
                ("profile", enumParam taskProfileNames "按所需工具选择：basic 提供搜索、上下文与媒体读取；browser 增加浏览器；sandbox 增加命令和文件操作，包括 SSH。研究任务也可选择 browser 或 sandbox。"),
                ("context", stringParam "显式传给子 agent 的上下文，最多 60000 字符。"),
                ("resources", stringArrayParam "可选的本会话 t#N:rM 结果句柄，最多 40 个；在 admission 时解析并冻结。"),
                ("inputs", object ["type" .= ("object" :: T.Text), "description" .= ("显式传给子 agent 的结构化 JSON 数据，最多 64 KiB。" :: T.Text)]),
                ("output_contract", object ["type" .= ("object" :: T.Text), "description" .= ("可选的闭合 JSON Schema 子集；给出时子 agent 的最终回复必须是符合契约的 JSON，宿主验证后放进 result.payload。只验证形状，不证明内容正确。" :: T.Text)]),
                ("wait", boolParam "true 表示在本次调用中等待报告并返回已结束的子 agent；默认 false，立即返回。")
              ]
              ["objective", "profile"],
          toolRunner = LegacyRunner
            $ parseArgs
              ( withObject "agent" $ \fields ->
                  (,,,,,,)
                    <$> fields .: "objective"
                    <*> fields .: "profile"
                    <*> fields .:? "context" .!= ""
                    <*> fields .:? "resources" .!= []
                    <*> fields .:? "inputs" .!= Null
                    <*> fields .:? "output_contract"
                    <*> fields .:? "wait" .!= False
              )
            $ \(objective, requested, explicitContext, resources, structured, contract, wait) -> case (durable, parseProfile requested) of
              (Just _, Just profile)
                | T.length explicitContext <= 60000 && length resources <= 40 && LBS.length (encode structured) <= 65536 -> do
                    resolved <- traverse resolveTurnResult resources
                    let grants = taskGrants profile (toolCatalogGrants context)
                        inputs = object (["context" .= explicitContext, "resources" .= Map.fromList (zip resources resolved)] <> ["inputs" .= structured | structured /= Null])
                    if Nothing `elem` resolved
                      then pure (Left "某个输入句柄无效、超出会话或已清除边界")
                      else case lookup profile [(Browser, "browser"), (Sandbox, "sandbox_exec")] of
                        Just required | not (Map.member required grants) -> pure (Left ("当前权限没有 " <> required <> "，不能派出 " <> profileName profile <> " 子 agent"))
                        _ -> fmap renderStart <$> startTask (TaskRequest objective profile inputs contract wait)
              _ -> pure (Left "缺少当前回合、profile 无效或输入过大")
        }
    renderStart = \case
      StartedTask job -> toJSON job
      FinishedTask job -> toJSON job
    controlTool operation =
      Tool
        { toolName = "agent_" <> State.taskOperationText operation,
          toolDescription = case operation of
            State.Steer -> "给指定 agent# 留下有归属的建议；收到建议不代表已经执行。"
            State.Replace -> "替换子 agent 的目标并取消旧执行；保留预算和截止时间。只有发起者可用。"
            _ -> "取消子 agent 及它派出的子 agent；已经发生的效果不会撤回。只有发起者可用。",
          toolSchema = toolObject [("agent", stringParam "agent# 标识"), ("note", stringParam "建议、替换目标或取消原因")] ["agent", "note"],
          toolRunner = LegacyRunner $
            parseArgs (withObject "agent control" $ \fields -> (,) <$> fields .: "agent" <*> fields .: "note") $
              \(handle, note) -> withHandle handle $ \identifier -> do
                let command = case operation of State.Steer -> SteerJob note; State.Replace -> ReplaceJob note; _ -> CancelJob note
                fmap (const (object ["accepted" .= True])) <$> controlTask identifier command
        }
    waitTool =
      legacyTool
        "agent_wait"
        "等待自己派出的子 agent 结束；收到新建议时提前返回。无需轮询，也不结束当前工作。"
        (toolObject [("agents", stringArrayParam "要等待的子 agent 的 agent#；省略表示全部。")] [])
        ( parseArgs (withObject "agent wait" (.:? "agents")) $ \requested ->
            case traverse parseTaskHandle (fromMaybe [] requested) of
              Nothing -> pure (Left "无效 agent# 标识")
              Just children -> fmap (fmap renderWait) (waitTasks children)
        )
    renderWait (ChildrenFinished children) = object ["children" .= children]

    progressTool =
      legacyTool
        "agent_progress"
        "记录内部进度，重复状态去重；可通过 agent_status 查询，更新会交给派出你的上级 agent。不向聊天发送过程播报；结束后才发送最终结果。"
        (toolObject [("summary", stringParam "当前进度、阻碍或正在验证的证据，最多 40000 字符。")] ["summary"])
        (parseArgs (withObject "agent progress" (.: "summary")) (fmap (either Left (const (Right (object ["recorded" .= True])))) . reportProgress))
