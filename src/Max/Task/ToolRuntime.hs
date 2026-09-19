-- | Scoped task-tool assembly.
module Max.Task.ToolRuntime (taskTools) where

import Effectful
import Effectful.PostgreSQL (WithConnection)
import Max.Effects.Blob (Blob)
import Max.Effects.TaskControl (TaskControl, TaskControlScope (..), runTaskControl)
import Max.Effects.TaskExecution (TaskExecution, runTaskExecution)
import Max.Effects.TaskQuery (TaskQuery, runTaskQuery)
import Max.Effects.Tools (Tool (..), hoistTool)
import Max.Effects.TurnQuery (TurnQuery, runTurnQuery)
import Max.Jobs (Jobs)
import Max.ToolContext
import Max.Tools.Task (taskToolsFor)
import Max.Turn.Types (AgentTurnRef (..), turnOutputAgentTurn)

taskTools :: forall es. (Blob :> es, WithConnection :> es, IOE :> es) => Jobs -> ToolContext -> [Tool es]
taskTools jobs context = map (hoistTool lower) (taskToolsFor context)
  where
    turn = turnOutputAgentTurn <$> toolTurnOutputContext context
    scope = TaskControlScope (toolGroupId context) turn (toolCanonicalId context) (toolAuthorPrincipalId context) (toolCatalogGrants context)
    lower :: forall x. Eff (TaskQuery : TaskControl : TaskExecution : TurnQuery : es) x -> Eff es x
    lower =
      runTurnQuery (toolConversationScope context) (toolClearedAt context)
        . runTaskExecution jobs ((.atrTurnId) <$> turn)
        . runTaskControl jobs scope
        . runTaskQuery jobs (toolGroupId context)
