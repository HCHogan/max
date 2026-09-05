module Max.Tools.Task (taskToolsFor, guardTaskResource) where

import Data.Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Parser, parseEither)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Effectful
import Effectful.PostgreSQL (WithConnection)
import Max.DB.AgentTurn (resolveJournalResultValue)
import Max.DB.Task
import Max.Effects.Blob (Blob)
import Max.Effects.Tools (Tool (..))
import Max.Task.Types
import Max.ToolContext
import Max.Tools.Schema (enumParam, integerParam, noArguments, stringArrayParam, stringParam, toolObject)
import Max.Turn.Types (AgentTurnRef (..), turnOutputAgentTurn)

taskToolsFor :: (Blob :> es, WithConnection :> es, IOE :> es) => ToolContext -> [Tool es]
taskToolsFor context =
  [ startTool,
    Tool "task_list" "列出本会话的持久化后台任务；完成后会主动通知，不需要轮询。" noArguments (\_ -> Right <$> listDurableTasks group),
    Tool
      "task_status"
      "查看指定任务的状态、证据、预算和未处理事件。"
      handleSchema
      (parseArgs (withObject "task_status" (.: "task")) $ \handle -> withHandle handle (fmap Right . taskStatus group))
  ]
    <> [controlTool operation | operation <- ["steer", "replace", "cancel"], not background || operation == "steer"]
    <> [finishTool | background]
  where
    group = toolGroupId context
    principal = toolAuthorPrincipalId context
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
          toolDescription = "把长研究、浏览器或 sandbox 工作交给后台。持久化后立即返回 task#，当前前台回合随即交还会话；不要等待或轮询。子任务不会直接向群里发言。profile 只收窄现有权限。每棵任务树共享 40 次工具预留、80 次模型请求和 10 分钟截止时间，重试不重置。token/cost 仅观测，不是硬额度。",
          toolSchema =
            toolObject
              [ ("key", stringParam "本回合内稳定的幂等键；同一工作重试必须复用。"),
                ("objective", stringParam "自包含目标、约束和期望证据，不依赖整段聊天记录。"),
                ("profile", enumParam ["research", "browser", "sandbox"] "research 默认只读；browser 或 sandbox 仅增加对应权限。"),
                ("context", stringParam "显式传给子任务的上下文，最多 12000 字符。"),
                ("resources", stringArrayParam "可选的本会话 t#N:rM 结果句柄，最多 8 个；在 admission 时解析并冻结。")
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
              (Just turn, Just profile)
                | T.length explicitContext <= 12000 && length resources <= 8 -> do
                    resolved <- traverse (resolveJournalResultValue (toolConversationScope context) (toolClearedAt context)) resources
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
                                admitted <-
                                  admitTask
                                    turn
                                    (toolCanonicalId context)
                                    principal
                                    key
                                    objective
                                    profile
                                    (object ["context" .= explicitContext, "resources" .= Map.fromList (zip resources resolved)])
                                    grants
                                pure (receipt (Map.keys grants) <$> result admitted)
              _ -> pure (Left "缺少持久化回合、profile 无效或输入过大")
        }
    controlTool operation =
      Tool
        { toolName = "task_" <> operation,
          toolDescription = case operation of
            "steer" -> "给指定 task# 留下有归属的建议。queued 只说明已可靠排队，不代表已执行；不能悄悄换目标。"
            "replace" -> "用 revision 做 compare-and-set 显式替换任务目标；旧执行被 fence，预算不会重置。只有发起者可用；管理员可用 !task 命令。"
            _ -> "取消指定 task# 及其子任务；先可靠记录并禁止后续效果，不保证撤回已经发生的效果。只有发起者可用；管理员可用 !task 命令。",
          toolSchema =
            toolObject
              [("task", stringParam "task# 标识"), ("note", stringParam "建议、替换目标或取消原因"), ("revision", integerParam "replace 必填的当前 revision")]
              (["task", "note"] <> ["revision" | operation == "replace"]),
          toolRun = parseArgs (withObject "task control" $ \fields -> (,,) <$> fields .: "task" <*> fields .: "note" <*> fields .:? "revision") $
            \(handle, note, revision) -> withHandle handle $ \identifier -> do
              if not background
                then result <$> taskControl group principal False identifier operation revision Nothing note
                else case durable of
                  Just turn -> result <$> steerChild turn.atrTurnId identifier note
                  Nothing -> pure (Left "缺少持久化任务上下文")
        }
    finishTool =
      Tool
        { toolName = "task_finish",
          toolDescription = "结束当前任务尝试：提交有证据和未解决项的报告。succeeded 代表你明确声明目标完成，不是由 prose/工具额度自动推断；waiting 用于等待用户或子任务。报告交回父任务或会话前台，不直接发群。",
          toolSchema =
            toolObject
              [ ("status", enumParam ["succeeded", "partial", "waiting", "failed"] "任务结果"),
                ("summary", stringParam "最多 8000 字符，明确发现、限制及下一步"),
                ("evidence", stringArrayParam "证据链接或本会话产物句柄；最多 16 条"),
                ("unresolved", stringArrayParam "未解决的问题；最多 16 条")
              ]
              ["status", "summary", "evidence", "unresolved"],
          toolRun = \raw -> case durable of
            Nothing -> pure (Left "没有任务执行上下文")
            Just turn -> case parseEither validateReport raw of
              Left detail -> pure (Left (T.pack detail))
              Right () -> do
                accepted <- taskReport turn.atrTurnId raw
                pure $ if accepted then Right (object ["returned" .= True]) else Left "报告无效或当前任务 revision/lease 已失效"
        }

validateReport :: Value -> Parser ()
validateReport = withObject "report" $ \fields -> do
  status <- fields .: "status"
  summary <- fields .: "summary"
  evidence <- fields .: "evidence" :: Parser [Text]
  unresolved <- fields .: "unresolved" :: Parser [Text]
  if status `elem` (["succeeded", "partial", "waiting", "failed"] :: [Text])
    && not (T.null (T.strip summary))
    && T.length summary <= 8000
    && length evidence <= 16
    && length unresolved <= 16
    then pure ()
    else fail "报告字段或长度无效"

result :: Value -> Either Text Value
result value@(Object fields) = case KeyMap.lookup "error" fields of
  Just (String detail) -> Left detail
  _ -> Right value
result value = Right value

receipt :: [Text] -> Value -> Value
receipt effectiveTools (Object fields) =
  Object . KeyMap.fromList $
    ("effective_tools", toJSON effectiveTools)
      : [(key, value) | key <- ["task_id", "revision", "status", "profile", "deadline", "max_calls", "max_rounds"], Just value <- [KeyMap.lookup key fields]]
receipt _ value = value

guardTaskResource :: (WithConnection :> es, IOE :> es) => ToolContext -> Tool es -> Tool es
guardTaskResource context tool = tool {toolRun = run}
  where
    run arguments = do
      allowed <- available arguments
      if not allowed
        then pure (Left "这个 sandbox 被另一个持久化任务占用；不要重试抢占，请创建独立 sandbox 或等待该任务释放。")
        else do
          outcome <- tool.toolRun arguments
          case (tool.toolName, outcome) of
            ("sandbox_create", Right value) -> do
              owned <- available value
              pure $ if owned then outcome else Left "sandbox 已创建但占用失败；请检查任务/资源状态，不要重复创建。"
            _ -> pure outcome
    available value = case (toolTurnOutputContext context, value) of
      (Just output, Object fields)
        | Just (String resource) <- KeyMap.lookup "sandbox_id" fields ->
            taskResource (turnOutputAgentTurn output).atrTurnId resource
      _ -> pure True
