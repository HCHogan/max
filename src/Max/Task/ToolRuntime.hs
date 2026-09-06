-- | Scoped task-tool assembly and the sandbox affinity resource boundary.
module Max.Task.ToolRuntime (taskToolsWithDatabase, guardTaskResource) where

import Data.Aeson (Value (..))
import Data.Aeson.KeyMap qualified as KeyMap
import Effectful
import Effectful.PostgreSQL (WithConnection)
import Max.DB.Task (taskResource)
import Max.Effects.Blob (Blob)
import Max.Effects.TaskControl (TaskControl, TaskControlScope (..), runTaskControl)
import Max.Effects.TaskExecution (TaskExecution, runTaskExecution)
import Max.Effects.TaskQuery (TaskQuery, runTaskQuery)
import Max.Effects.ToolControl (ToolControl)
import Max.Effects.Tools (Tool (..), hoistTool)
import Max.Effects.TurnQuery (TurnQuery, runTurnQuery)
import Max.ToolContext
import Max.Tools.Task (taskToolsFor)
import Max.Turn.Types (AgentTurnRef (..), turnOutputAgentTurn)

taskToolsWithDatabase :: forall es. (ToolControl :> es, Blob :> es, WithConnection :> es, IOE :> es) => ToolContext -> [Tool es]
taskToolsWithDatabase context = map (hoistTool lower) (taskToolsFor context)
  where
    turn = turnOutputAgentTurn <$> toolTurnOutputContext context
    scope = TaskControlScope (toolGroupId context) turn (toolCanonicalId context) (toolAuthorPrincipalId context) (toolCatalogGrants context) (toolCapabilities context).tcBackground
    lower :: forall x. Eff (TaskQuery : TaskControl : TaskExecution : TurnQuery : es) x -> Eff es x
    lower =
      runTurnQuery (toolConversationScope context) (toolClearedAt context)
        . runTaskExecution ((.atrTurnId) <$> turn)
        . runTaskControl scope
        . runTaskQuery (toolGroupId context)

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
