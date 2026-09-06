-- | Bind memory tools to the current caller without exposing the store.
module Max.Memory.ToolRuntime (memoryToolsWithDatabase) where

import Effectful
import Effectful.Log (Log)
import Effectful.PostgreSQL (WithConnection)
import Max.Effects.MemoryControl (MemoryControl, MemoryControlScope (..), runMemoryControl)
import Max.Effects.MemoryQuery (MemoryQuery, runMemoryQuery)
import Max.Effects.Tools (Tool, hoistTool)
import Max.ToolContext
import Max.Tools.Memory (memoryToolsFor)
import Max.Turn.Types (AgentTurnRef (..), turnOutputAgentTurn)

memoryToolsWithDatabase :: forall es. (WithConnection :> es, Log :> es, IOE :> es) => ToolContext -> [Tool es]
memoryToolsWithDatabase context = map (hoistTool lower) memoryToolsFor
  where
    scope = MemoryControlScope (toolGroupId context) ((.atrTurnId) . turnOutputAgentTurn <$> toolTurnOutputContext context) (toolAuthorPrincipalId context) (toolCanonicalId context)
    lower :: forall a. Eff (MemoryQuery : MemoryControl : es) a -> Eff es a
    lower = runMemoryControl scope . runMemoryQuery (toolConversationScope context) (toolAuthorPrincipalId context)
