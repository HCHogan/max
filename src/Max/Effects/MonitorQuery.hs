{-# LANGUAGE TypeFamilies #-}

-- | Read monitor facts in the conversation bound by host assembly.
module Max.Effects.MonitorQuery (MonitorQuery, listReminders, listMonitors, readMonitorHistory, runMonitorQuery) where

import Effectful
import Effectful.Dispatch.Dynamic (interpret, send)
import Effectful.PostgreSQL (WithConnection)
import Max.ConversationScope (ConversationScope, conversationStorageId)
import Max.DB.Monitor qualified as DB
import Max.DB.Task.Overview qualified as Overview
import Max.Monitor.Types (MonitorOrdinal (..))
import Max.Monitor.View (ArmedMonitor, TimeMonitor)
import Max.Task.Overview (MonitorHistory)
import OneBot.Types (GroupId (..))

data MonitorQuery :: Effect where
  ListReminders :: MonitorQuery m [TimeMonitor]
  ListMonitors :: MonitorQuery m [ArmedMonitor]
  ReadMonitorHistory :: MonitorOrdinal -> MonitorQuery m (Maybe MonitorHistory)

type instance DispatchOf MonitorQuery = Dynamic

listReminders :: (MonitorQuery :> es) => Eff es [TimeMonitor]
listReminders = send ListReminders

listMonitors :: (MonitorQuery :> es) => Eff es [ArmedMonitor]
listMonitors = send ListMonitors

readMonitorHistory :: (MonitorQuery :> es) => MonitorOrdinal -> Eff es (Maybe MonitorHistory)
readMonitorHistory = send . ReadMonitorHistory

runMonitorQuery :: (WithConnection :> es, IOE :> es) => ConversationScope -> Eff (MonitorQuery : es) a -> Eff es a
runMonitorQuery scope = interpret $ \_ -> \case
  ListReminders -> DB.listCannedTimeMonitors scope
  ListMonitors -> DB.listArmedMonitors scope
  ReadMonitorHistory ordinal -> Overview.readMonitorHistory (GroupId (conversationStorageId scope)) ordinal.unMonitorOrdinal
