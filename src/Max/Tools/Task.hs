module Max.Tools.Task (taskToolsFor) where

import Data.Aeson
import Data.Aeson.Types (parseEither)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Effectful
import Max.Effects.TaskControl
  ( TaskControl,
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
  ( enumParam,
    noArguments,
    stringArrayParam,
    stringParam,
    toolObject,
  )
import Max.Turn.Types (turnOutputAgentTurn)

taskToolsFor :: (TaskQuery :> es, TaskControl :> es, TaskExecution :> es, TurnQuery :> es) => ToolContext -> [Tool es]
taskToolsFor context =
  [ startTool,
    legacyTool "task_list" "列出本会话的当前进程的后台任务；完成后会主动通知，不需要轮询。" noArguments (\_ -> Right . toJSON <$> listTasks),
    legacyTool
      "task_status"
      "查看指定任务的状态、证据、预算和未处理事件。"
      handleSchema
      (parseArgs (withObject "task_status" (.: "task")) $ \handle -> withHandle handle (fmap (maybe (Left "task not found in this conversation") (Right . toJSON)) . readTask))
  ]
    <> [controlTool operation | operation <- [State.Steer, State.Replace, State.Cancel], not background || operation == State.Steer]
    <> (if background then [waitTool, progressTool] else [])
  where
    background = (toolCapabilities context).tcBackground
    durable = turnOutputAgentTurn <$> toolTurnOutputContext context
    handleSchema = toolObject [("task", stringParam "task# 标识；必须来自本会话。")] ["task"]
    withHandle handle action = maybe (pure (Left "无效 task# 标识")) action (parseTaskHandle handle)
    parseArgs parser action raw = case parseEither parser raw of
      Left detail -> pure (Left (T.pack detail))
      Right args -> action args
    startTool =
      Tool
        { toolName = "task_start",
          toolDescription = "把长研究、浏览器、sandbox 或 SSH 运维工作交给后台。启动后立即返回 task#，简短告知用户任务已启动即可结束本轮；不要等待或轮询。后台不会直接向群里发言；任务结束后报告会交回前台，由你转述给发起者。profile 只收窄现有权限。每棵任务树共享 200 次工具预留、400 次模型请求和六小时截止时间，替换目标不重置。token/cost 仅观测，不是硬额度。",
          toolSchema =
            toolObject
              [ ("objective", stringParam "自包含目标、约束和期望证据，不依赖整段聊天记录。"),
                ("profile", enumParam taskProfileNames "按所需工具选择：basic 提供搜索、上下文与媒体读取；browser 增加浏览器；sandbox 增加命令和文件操作，包括 SSH。研究任务也可选择 browser 或 sandbox。"),
                ("context", stringParam "显式传给子任务的上下文，最多 60000 字符。"),
                ("resources", stringArrayParam "可选的本会话 t#N:rM 结果句柄，最多 40 个；在 admission 时解析并冻结。")
              ]
              ["objective", "profile"],
          toolRunner = LegacyRunner
            $ parseArgs
              ( withObject "task_start" $ \fields ->
                  (,,,)
                    <$> fields .: "objective"
                    <*> fields .: "profile"
                    <*> fields .:? "context" .!= ""
                    <*> fields .:? "resources" .!= []
              )
            $ \(objective, requested, explicitContext, resources) -> case (durable, parseProfile requested) of
              (Just _, Just profile)
                | T.length explicitContext <= 60000 && length resources <= 40 -> do
                    resolved <- traverse resolveTurnResult resources
                    let grants = taskGrants profile (toolCatalogGrants context)
                    if Nothing `elem` resolved
                      then pure (Left "某个输入句柄无效、超出会话或已清除边界")
                      else case lookup profile [(Browser, "browser"), (Sandbox, "sandbox_exec")] of
                        Just required | not (Map.member required grants) -> pure (Left ("当前权限没有 " <> required <> "，不能启动 " <> profileName profile <> " 任务"))
                        _ -> do
                          admitted <- startTask objective profile (object ["context" .= explicitContext, "resources" .= Map.fromList (zip resources resolved)])
                          case admitted of
                            Left failure -> pure (Left failure)
                            Right accepted -> pure (Right (toJSON accepted))
              _ -> pure (Left "缺少当前回合、profile 无效或输入过大")
        }
    controlTool operation =
      Tool
        { toolName = "task_" <> State.taskOperationText operation,
          toolDescription = case operation of
            State.Steer -> "给指定 task# 留下有归属的建议；收到建议不代表已经执行。"
            State.Replace -> "替换任务目标并取消旧执行；保留预算和截止时间。只有发起者可用。"
            _ -> "取消任务及其子任务；已经发生的效果不会撤回。只有发起者可用。",
          toolSchema = toolObject [("task", stringParam "task# 标识"), ("note", stringParam "建议、替换目标或取消原因")] ["task", "note"],
          toolRunner = LegacyRunner $
            parseArgs (withObject "task control" $ \fields -> (,) <$> fields .: "task" <*> fields .: "note") $
              \(handle, note) -> withHandle handle $ \identifier -> do
                let command = case operation of State.Steer -> SteerJob note; State.Replace -> ReplaceJob note; _ -> CancelJob note
                fmap (const (object ["accepted" .= True])) <$> controlTask identifier command
        }
    waitTool =
      legacyTool
        "task_wait"
        "等待本任务的子任务完成；收到新建议时提前返回。无需轮询，也不结束当前任务。"
        (toolObject [("tasks", stringArrayParam "要等待的子任务 task#；省略表示全部子任务。")] [])
        ( parseArgs (withObject "task wait" (.:? "tasks")) $ \requested ->
            case traverse parseTaskHandle (fromMaybe [] requested) of
              Nothing -> pure (Left "无效 task# 标识")
              Just children -> fmap (fmap renderWait) (waitTasks children)
        )
    renderWait (ChildrenFinished children) = object ["children" .= children]
    renderWait FeedbackPending = object ["feedback_pending" .= True]

    progressTool =
      legacyTool
        "task_progress"
        "记录内部进度，重复状态去重；可通过 task_status 查询，子任务更新交给父任务。不向聊天发送过程播报；任务结束后才发送最终结果。"
        (toolObject [("summary", stringParam "当前进度、阻碍或正在验证的证据，最多 40000 字符。")] ["summary"])
        (parseArgs (withObject "task progress" (.: "summary")) (fmap (either Left (const (Right (object ["recorded" .= True])))) . reportProgress))
