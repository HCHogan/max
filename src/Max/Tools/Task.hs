module Max.Tools.Task (taskToolsFor) where

import Data.Aeson
import Data.Aeson.Types (parseEither)
import Data.Map.Strict qualified as Map
import Data.Maybe (isNothing)
import Data.Text (Text)
import Data.Text qualified as T
import Effectful
import Max.Effects.TaskControl (TaskControl, controlTask, startTask)
import Max.Effects.TaskExecution (TaskExecution, reportProgress, reportRequest, reportTask)
import Max.Effects.TaskQuery (TaskQuery, listTasks, readTask)
import Max.Effects.ToolControl (ToolControl, finishExecution, yieldFrontend)
import Max.Effects.Tools (Tool (..))
import Max.Effects.TurnQuery (TurnQuery, resolveTurnResult)
import Max.Task.Admission (TaskAdmissionReceipt (..), admissionErrorText)
import Max.Task.Execution (renderExecutionFailure)
import Max.Task.State qualified as State
import Max.Task.Types
import Max.ToolContext
import Max.Tools.Schema (enumParam, integerParam, noArguments, stringArrayParam, stringParam, toolObject)
import Max.Turn.Types (turnOutputAgentTurn)

taskToolsFor :: (ToolControl :> es, TaskQuery :> es, TaskControl :> es, TaskExecution :> es, TurnQuery :> es) => ToolContext -> [Tool es]
taskToolsFor context =
  [ startTool,
    Tool "task_list" "列出本会话的持久化后台任务；完成后会主动通知，不需要轮询。" noArguments (\_ -> Right . toJSON <$> listTasks),
    Tool
      "task_status"
      "查看指定任务的状态、证据、预算和未处理事件。"
      handleSchema
      (parseArgs (withObject "task_status" (.: "task")) $ \handle -> withHandle handle (fmap (maybe (Left "task not found in this conversation") (Right . toJSON)) . readTask))
  ]
    <> [controlTool operation | operation <- [State.Steer, State.Replace, State.Cancel], not background || operation == State.Steer]
    <> (if background then [finishTool, progressTool] else [requestFinishTool | isNothing (toolEffectCeiling context)])
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
          toolDescription = "把长研究、浏览器或 sandbox 工作交给后台。持久化后立即返回 task#，当前前台回合随即交还会话；不要等待或轮询。子任务不会直接向群里发言。profile 只收窄现有权限。每棵任务树共享 200 次工具预留、400 次模型请求和 50 分钟截止时间，重试不重置。token/cost 仅观测，不是硬额度。",
          toolSchema =
            toolObject
              [ ("key", stringParam "本回合内稳定的幂等键；同一工作重试必须复用。"),
                ("objective", stringParam "自包含目标、约束和期望证据，不依赖整段聊天记录。"),
                ("profile", enumParam ["research", "browser", "sandbox"] "research 默认只读；browser 或 sandbox 仅增加对应权限。"),
                ("context", stringParam "显式传给子任务的上下文，最多 60000 字符。"),
                ("resources", stringArrayParam "可选的本会话 t#N:rM 结果句柄，最多 40 个；在 admission 时解析并冻结。")
              ]
              ["key", "objective", "profile"],
          toolRun = parseArgs
            ( withObject "task_start" $ \fields ->
                (,,,,)
                  <$> fields .: "key"
                  <*> fields .: "objective"
                  <*> fields .: "profile"
                  <*> fields .:? "context" .!= ""
                  <*> fields .:? "resources" .!= []
            )
            $ \(key, objective, requested, explicitContext, resources) -> case (durable, parseProfile requested) of
              (Just _, Just profile)
                | T.length explicitContext <= 60000 && length resources <= 40 -> do
                    resolved <- traverse resolveTurnResult resources
                    let grants = taskGrants profile (toolCatalogGrants context)
                    if Nothing `elem` resolved
                      then pure (Left "某个输入句柄无效、超出会话或已清除边界")
                      else
                        if profile == Browser && not (Map.member "browser_navigate" grants)
                          then pure (Left "当前权限没有 browser_navigate，不能启动 browser 任务")
                          else
                            if profile == Sandbox && not (Map.member "sandbox_exec" grants)
                              then pure (Left "当前权限没有 sandbox_exec，不能启动 sandbox 任务")
                              else do
                                admitted <- startTask key objective profile (object ["context" .= explicitContext, "resources" .= Map.fromList (zip resources resolved)])
                                case admitted of
                                  Left failure -> pure (Left (admissionErrorText failure))
                                  Right accepted -> do
                                    if background then pure () else yieldFrontend ("已交给后台任务 " <> taskHandle accepted.taskId <> "，完成后会通知；现在可以继续问别的问题。")
                                    pure (Right (toJSON accepted))
              _ -> pure (Left "缺少持久化回合、profile 无效或输入过大")
        }
    controlTool operation =
      Tool
        { toolName = "task_" <> State.taskOperationText operation,
          toolDescription = case operation of
            State.Steer -> "给指定 task# 留下有归属的建议。queued 只说明已可靠排队，不代表已执行；不能悄悄换目标。"
            State.Replace -> "用 revision 做 compare-and-set 显式替换任务目标；旧执行被 fence，预算不会重置。只有发起者可用；管理员可用 !task 命令。"
            _ -> "取消指定 task# 及其子任务；先可靠记录并禁止后续效果，不保证撤回已经发生的效果。只有发起者可用；管理员可用 !task 命令。",
          toolSchema =
            toolObject
              [("task", stringParam "task# 标识"), ("note", stringParam "建议、替换目标或取消原因"), ("revision", integerParam "replace 必填的当前 revision")]
              (["task", "note"] <> ["revision" | operation == State.Replace]),
          toolRun = parseArgs (withObject "task control" $ \fields -> (,,) <$> fields .: "task" <*> fields .: "note" <*> fields .:? "revision") $
            \(handle, note, revision) -> withHandle handle $ \identifier ->
              either (Left . State.renderTaskControlError) (Right . toJSON) <$> controlTask identifier operation revision note
        }
    finishTool =
      Tool
        { toolName = "task_finish",
          toolDescription = "结束当前任务尝试：提交有证据和未解决项的报告。succeeded 代表你明确声明目标完成，不是由 prose/工具额度自动推断；waiting 用于等待用户或子任务。报告交回父任务或会话前台，不直接发群。",
          toolSchema =
            toolObject
              [ ("status", enumParam ["succeeded", "partial", "waiting", "failed"] "任务结果"),
                ("summary", stringParam "最多 40000 字符，明确发现、限制及下一步"),
                ("evidence", stringArrayParam "证据链接或本会话产物句柄；最多 80 条"),
                ("unresolved", stringArrayParam "未解决的问题；最多 80 条"),
                ("failure_kind", enumParam ["permanent", "transient"] "failed 时说明错误是否暂时性；未知外部效果不能自动重试。"),
                ("observation", object ["description" .= ("monitor 的稳定结构化观测值，排除叙述和当前时间；变化通知比较此值。" :: Text)])
              ]
              ["status", "summary", "evidence", "unresolved"],
          toolRun = \raw -> case State.parseTaskReport raw of
            Left detail -> pure (Left detail)
            Right report ->
              reportTask report >>= \case
                Left failure -> pure (Left (renderExecutionFailure failure))
                Right () -> finishExecution Nothing >> pure (Right (object ["returned" .= True]))
        }

    progressTool =
      Tool
        "task_progress"
        "记录持久化进度；重复状态去重，待发布进度合并。只交给父任务或协调前台，不直接发群。"
        (toolObject [("summary", stringParam "当前进度、阻碍或正在验证的证据，最多 40000 字符。")] ["summary"])
        (parseArgs (withObject "task progress" (.: "summary")) (fmap (either (Left . renderExecutionFailure) (const (Right (object ["recorded" .= True])))) . reportProgress))
    requestFinishTool =
      Tool
        "request_finish"
        "明确结束前台请求：answered 已回答，waiting 正在向用户询问缺失信息，declined 明确拒绝。reply 是要发给用户的最终内容；不要先用其他工具重复发送。"
        (toolObject [("disposition", enumParam ["answered", "waiting", "declined"] "请求的真实处置"), ("reply", stringParam "给用户的完整答复或明确的澄清问题，最多 40000 字符。")] ["disposition", "reply"])
        ( parseArgs (withObject "request_finish" $ \fields -> (,) <$> fields .: "disposition" <*> fields .: "reply") $ \(disposition, reply) -> case State.parseDisposition disposition of
            Nothing -> pure (Left "无效请求处置")
            Just typed ->
              reportRequest typed reply >>= \case
                Left failure -> pure (Left (renderExecutionFailure failure))
                Right () -> finishExecution (Just (T.strip reply)) >> pure (Right (object ["returned" .= True, "reply" .= T.strip reply]))
        )
