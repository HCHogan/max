-- | Bind the current caller before exposing the pin-only capability.
module Max.Pin.ToolRuntime (pinToolsWithDatabase) where

import Data.Text (Text)
import Effectful
import Effectful.Log (Log)
import Effectful.PostgreSQL (WithConnection)
import Max.Effects.PinControl (PinControlScope (..), runPinControl)
import Max.Effects.Tools (Tool, hoistTool)
import Max.Session (SessionRegistry)
import Max.ToolContext
import Max.Tools.Pins (pinToolsFor)
import Max.Turn.Types (AgentTurnRef (..), turnOutputAgentTurn)

pinToolsWithDatabase :: (WithConnection :> es, Log :> es, IOE :> es) => SessionRegistry -> Text -> ToolContext -> [Tool es]
pinToolsWithDatabase sessions defaultModel context = map (hoistTool (runPinControl scope sessions defaultModel)) pinToolsFor
  where
    scope = PinControlScope (toolGroupId context) ((.atrTurnId) . turnOutputAgentTurn <$> toolTurnOutputContext context) (toolAuthorPrincipalId context)
