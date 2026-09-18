module Max.Tools.Task (taskToolsFor) where

import Data.Aeson
import Data.Aeson.Types (parseEither)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Effectful
import Max.Effects.TaskControl
  ( TaskControl,
    controlTask,
    startTask,
  )
import Max.Effects.TaskExecution
  ( TaskExecution,
    reportProgress,
    reportTask,
  )
import Max.Effects.TaskQuery (TaskQuery, listTasks, readTask)
import Max.Effects.ToolControl
  ( ToolControl,
    finishExecution,
  )
import Max.Effects.Tools (Tool (..), ToolRunner (..), legacyTool)
import Max.Effects.TurnQuery (TurnQuery, resolveTurnResult)
import Max.Task.Admission (admissionErrorText)
import Max.Task.Execution (renderExecutionFailure)
import Max.Task.State qualified as State
import Max.Task.Types
import Max.ToolContext
import Max.Tools.Schema
  ( enumParam,
    integerParam,
    noArguments,
    stringArrayParam,
    stringParam,
    toolObject,
  )
import Max.Turn.Types (turnOutputAgentTurn)

taskToolsFor :: (ToolControl :> es, TaskQuery :> es, TaskControl :> es, TaskExecution :> es, TurnQuery :> es) => ToolContext -> [Tool es]
taskToolsFor context =
  [ startTool,
    legacyTool "task_list" "列出本会话的持久化后台任务；完成后会主动通知，不需要轮询。" noArguments (\_ -> Right . toJSON <$> listTasks),
    legacyTool
      "task_status"
      "查看指定任务的状态、证据、预算和未处理事件。"
      handleSchema
      (parseArgs (withObject "task_status" (.: "task")) $ \handle -> withHandle handle (fmap (maybe (Left "task not found in this conversation") (Right . toJSON)) . readTask))
  ]
    <> [controlTool operation | operation <- [State.Steer, State.Replace, State.Cancel], not background || operation == State.Steer]
    <> (if background then [finishTool, progressTool] else [])
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
          toolDescription = "把长研究、浏览器、sandbox 或 SSH 运维工作交给后台。持久化后立即返回 task#，简短告知用户任务已启动即可结束本轮；不要等待或轮询。子任务不会直接向群里发言。profile 只收窄现有权限。每棵任务树共享 200 次工具预留、400 次模型请求和六小时截止时间，重试不重置。token/cost 仅观测，不是硬额度。",
          toolSchema =
            toolObject
              [ ("key", stringParam "本回合内稳定的幂等键；同一工作重试必须复用。"),
                ("objective", stringParam "自包含目标、约束和期望证据，不依赖整段聊天记录。"),
                ("profile", enumParam taskProfileNames "research 默认只读；browser 使用浏览器；sandbox 执行命令，包括 SSH 运维。运维方法加载 operations 技能。"),
                ("context", stringParam "显式传给子任务的上下文，最多 60000 字符。"),
                ("resources", stringArrayParam "可选的本会话 t#N:rM 结果句柄，最多 40 个；在 admission 时解析并冻结。")
              ]
              ["key", "objective", "profile"],
          toolRunner = LegacyRunner
            $ parseArgs
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
                      else case lookup profile [(Browser, "browser"), (Sandbox, "sandbox_exec")] of
                        Just required | not (Map.member required grants) -> pure (Left ("当前权限没有 " <> required <> "，不能启动 " <> profileName profile <> " 任务"))
                        _ -> do
                          admitted <- startTask key objective profile (object ["context" .= explicitContext, "resources" .= Map.fromList (zip resources resolved)])
                          case admitted of
                            Left failure -> pure (Left (admissionErrorText failure))
                            Right accepted -> pure (Right (toJSON accepted))
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
          toolRunner = LegacyRunner $
            parseArgs (withObject "task control" $ \fields -> (,,) <$> fields .: "task" <*> fields .: "note" <*> fields .:? "revision") $
              \(handle, note, revision) -> withHandle handle $ \identifier ->
                case State.taskCommand operation revision note of
                  Left failure -> pure (Left (State.renderTaskControlError failure))
                  Right command -> either (Left . State.renderTaskControlError) (Right . toJSON) <$> controlTask (State.DurableTaskId identifier) command
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
                ("observation", object ["description" .= ("change_only monitor 完成时必填非空对象；沿用 previous_observation 的键和类型，只放稳定业务状态。时间、报告措辞、job ID 放 evidence，不放此处。" :: Text)]),
                ("payload", object ["description" .= ("委派输入指定 output_contract 时，succeeded 必须在此返回遵循该契约的 JSON；形状正确不代表目标已经完成，仍需 summary、evidence、unresolved。" :: Text)])
              ]
              ["status", "summary", "evidence", "unresolved"],
          toolRunner = LegacyRunner $ \raw -> case State.parseTaskReport raw of
            Left detail -> pure (Left detail)
            Right report ->
              reportTask report >>= \case
                Left failure -> pure (Left (renderExecutionFailure failure))
                Right () -> finishExecution Nothing >> pure (Right (object ["returned" .= True]))
        }

    progressTool =
      legacyTool
        "task_progress"
        "记录进度；重复状态去重，尚未发送的进度合并。子任务交给父任务；根任务直接发送最新摘要，请用简洁的用户可读正文。"
        (toolObject [("summary", stringParam "当前进度、阻碍或正在验证的证据，最多 40000 字符。")] ["summary"])
        (parseArgs (withObject "task progress" (.: "summary")) (fmap (either (Left . renderExecutionFailure) (const (Right (object ["recorded" .= True])))) . reportProgress))
