module Max.Hook.ToolRuntime (hookToolsWithDatabase) where

import Effectful
import Effectful.PostgreSQL (WithConnection)
import Max.Effects.HookControl (HookControl, runHookControl)
import Max.Effects.HookQuery (HookQuery, runHookQuery)
import Max.Effects.Tools (Tool, hoistTool)
import Max.ToolContext
import Max.Tools.Hooks (hookTools)
import Max.Turn.Types (AgentTurnRef (atrTurnId), turnOutputAgentTurn)

hookToolsWithDatabase :: forall es. (WithConnection :> es, IOE :> es) => ToolContext -> [Tool es]
hookToolsWithDatabase context = map (hoistTool lower) hookTools
  where
    lower :: forall a. Eff (HookControl : HookQuery : es) a -> Eff es a
    lower action =
      runHookQuery (toolConversationScope context) (toolMonitorArmingAllowed context) $
        runHookControl (toolCallAuthority context) ((.atrTurnId) . turnOutputAgentTurn <$> toolTurnOutputContext context) (toolGroupId context) (toolAuthorPrincipalId context) (toolMonitorArmingAllowed context) action
