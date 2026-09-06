-- | The database and clock boundary for monitor/reminder tool invocations.
module Max.Monitor.ToolRuntime (monitorToolsWithDatabase, reminderToolsWithDatabase) where

import Data.Time (TimeZone, UTCTime, getCurrentTime)
import Effectful
import Effectful.PostgreSQL (WithConnection)
import Effectful.Reader.Static (Reader, runReader)
import Max.Effects.MonitorControl (MonitorControl, MonitorControlScope (..), runMonitorControl)
import Max.Effects.MonitorQuery (MonitorQuery, runMonitorQuery)
import Max.Effects.Tools (Tool, hoistTool)
import Max.ToolContext
import Max.Tools.Monitor (monitorToolsFor)
import Max.Tools.Reminder (reminderToolsFor)
import Max.Turn.Types (turnOutputAgentTurn)

monitorToolsWithDatabase :: (WithConnection :> es, IOE :> es) => TimeZone -> ToolContext -> [Tool es]
monitorToolsWithDatabase tz context = map (hoistTool (runMonitorTools context)) (monitorToolsFor tz)

reminderToolsWithDatabase :: (WithConnection :> es, IOE :> es) => TimeZone -> ToolContext -> [Tool es]
reminderToolsWithDatabase tz context = map (hoistTool (runMonitorTools context)) (reminderToolsFor tz)

runMonitorTools :: (WithConnection :> es, IOE :> es) => ToolContext -> Eff (MonitorQuery : MonitorControl : Reader UTCTime : es) a -> Eff es a
runMonitorTools context action = do
  now <- liftIO getCurrentTime
  runReader now $
    runMonitorControl scope $
      runMonitorQuery (toolConversationScope context) action
  where
    scope = MonitorControlScope (toolGroupId context) (turnOutputAgentTurn <$> toolTurnOutputContext context) (toolAuthorPrincipalId context) (toolCatalogGrants context) (toolMonitorArmingAllowed context)
