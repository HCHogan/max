-- | Bind conversation and turn reads before exposing built-in tool runners.
module Max.Conversation.ToolRuntime (builtinsWithDatabase, groupToolsWithDatabase) where

import Data.Time (TimeZone)
import Effectful
import Effectful.Log (Log)
import Effectful.PostgreSQL (WithConnection)
import Max.Effects.Blob (Blob)
import Max.Effects.ConversationQuery (ConversationQuery, runConversationQuery, runConversationQueryWithObservations)
import Max.Effects.Embedding (Embedding)
import Max.Effects.Http (Http)
import Max.Effects.PlatformInteraction (PlatformInteraction)
import Max.Effects.PlatformQuery (PlatformQuery)
import Max.Effects.ToolOutput (ToolOutput)
import Max.Effects.Tools (Tool, hoistTool)
import Max.Effects.TurnQuery (TurnQuery, runTurnQuery)
import Max.Jobs qualified as Jobs
import Max.ToolContext
import Max.Tools (builtinsFor)
import Max.Tools.Group (groupToolsFor)
import Max.Turn.Types (AgentTurnRef (..), turnOutputAgentTurn)

builtinsWithDatabase :: forall es. (Blob :> es, Embedding :> es, Log :> es, PlatformInteraction :> es, WithConnection :> es, IOE :> es) => Jobs.Jobs -> TimeZone -> ToolContext -> [Tool es]
builtinsWithDatabase jobs tz context = map (hoistTool lower) (builtinsFor tz context)
  where
    lower :: forall a. Eff (ConversationQuery : TurnQuery : es) a -> Eff es a
    lower = runTurnQuery (toolConversationScope context) (toolClearedAt context) . runConversationQueryWithObservations (toolConversationScope context) (Jobs.readObservationPage jobs (toolGroupId context) ((.atrTurnId) . turnOutputAgentTurn <$> toolTurnOutputContext context))

groupToolsWithDatabase :: (PlatformQuery :> es, Http :> es, Log :> es, ToolOutput :> es, WithConnection :> es, IOE :> es) => ToolContext -> [Tool es]
groupToolsWithDatabase context = map (hoistTool (runConversationQuery (toolConversationScope context))) (groupToolsFor context)
