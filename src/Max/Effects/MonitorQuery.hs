{-# LANGUAGE TypeFamilies #-}

-- | Read monitor facts in the conversation bound by host assembly.
module Max.Effects.MonitorQuery (MonitorQuery, listMonitors, readMonitorHistory, runMonitorQuery) where

import Effectful
import Effectful.Dispatch.Dynamic (interpret, send)
import Effectful.PostgreSQL (WithConnection)
import Max.ConversationScope (ConversationScope, conversationStorageId)
import Max.DB.Monitor qualified as DB
import Max.DB.Monitor.Overview qualified as Overview
import Max.Monitor.Types (MonitorOrdinal (..))
import Max.Monitor.View (ArmedMonitor, MonitorHistory)
import OneBot.Types (GroupId (..))

data MonitorQuery :: Effect where
  ListMonitors :: MonitorQuery m [ArmedMonitor]
  ReadMonitorHistory :: MonitorOrdinal -> MonitorQuery m (Maybe MonitorHistory)

type instance DispatchOf MonitorQuery = Dynamic

listMonitors :: (MonitorQuery :> es) => Eff es [ArmedMonitor]
listMonitors = send ListMonitors

readMonitorHistory :: (MonitorQuery :> es) => MonitorOrdinal -> Eff es (Maybe MonitorHistory)
readMonitorHistory = send . ReadMonitorHistory

runMonitorQuery :: (WithConnection :> es, IOE :> es) => ConversationScope -> Eff (MonitorQuery : es) a -> Eff es a
runMonitorQuery scope = interpret $ \_ -> \case
  ListMonitors -> DB.listArmedMonitors scope
  ReadMonitorHistory ordinal -> Overview.readMonitorHistory (GroupId (conversationStorageId scope)) ordinal.unMonitorOrdinal
