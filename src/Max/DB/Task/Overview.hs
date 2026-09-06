-- | Durable work projections use typed columns in one stable read snapshot.
-- Limits and set filtering stay in SQL; presentation belongs to domain views.
module Max.DB.Task.Overview (readMonitorHistory, readWorkOverview) where

import Data.Int (Int64)
import Data.Map.Strict qualified as Map
import Database.PostgreSQL.Simple.FromRow (RowParser, field)
import Database.PostgreSQL.Simple.Types (Only (..), PGArray (..))
import Effectful
import Effectful.PostgreSQL (WithConnection, query)
import Max.DB.Codec (enumField, queryRows)
import Max.DB.Transaction (withReadSnapshot)
import Max.Monitor.Policy (parseOccurrenceDisposition, parseOverlapPolicy)
import Max.Task.Overview
import Max.Task.State (parseTaskStatus)
import Max.Task.Types (parseProfile)
import OneBot.Types (GroupId (..))

readMonitorHistory :: (WithConnection :> es, IOE :> es) => GroupId -> Int64 -> Eff es (Maybe MonitorHistory)
readMonitorHistory (GroupId group) ordinal = withReadSnapshot $ do
  definitions <-
    queryRows
      ((,) <$> field <*> definitionRow)
      "SELECT monitor_id,monitor_ordinal,definition_revision,goal_text,task_profile,status,overlap_policy,queue_limit,change_only,next_fire_at\
      \ FROM monitors JOIN conversations USING(conversation_id) WHERE legacy_group_id=? AND monitor_ordinal=?"
      (group, ordinal)
  case definitions of
    [(identifier :: Int64, definition)] -> do
      fires <-
        queryRows
          occurrenceRow
          "SELECT fire_id,definition_revision,scheduled_at,disposition,task_id,coalesced_into,admission_state,left(trigger_evidence,5000),last_error\
          \ FROM monitor_fires WHERE monitor_id=? ORDER BY fire_id DESC LIMIT 150"
          (Only identifier)
      pure (Just (MonitorHistory definition fires))
    _ -> pure Nothing
  where
    definitionRow = MonitorDefinition <$> field <*> field <*> field <*> enumField parseProfile <*> enumField parseMonitorStatus <*> enumField parseOverlapPolicy <*> field <*> field <*> field
    occurrenceRow = MonitorOccurrence <$> field <*> field <*> field <*> enumField parseOccurrenceDisposition <*> field <*> field <*> enumField parseAdmissionState <*> field <*> field

readWorkOverview :: (WithConnection :> es, IOE :> es) => Eff es WorkOverview
readWorkOverview = withReadSnapshot $ do
  tasks <-
    queryRows
      taskRow
      "SELECT task_id,legacy_group_id,owner_principal_id,revision,status,profile,left(objective,1500),\
      \ calls_reserved,max_calls,rounds_reserved,max_rounds,deadline,retry_count,next_attempt_at,last_error,\
      \ (SELECT body->>'summary' FROM task_progress WHERE task_id=work.task_id AND revision=work.revision),\
      \ (SELECT count(*) FROM task_notifications WHERE task_id=work.task_id AND revision=work.revision AND attempt=work.attempt\
      \ AND superseded_at IS NULL AND delivered_at IS NULL AND attempts>=15),left(result::text,10000)\
      \ FROM durable_tasks work JOIN conversations USING(conversation_id) ORDER BY task_id DESC LIMIT 500"
      ()
  monitors <-
    queryRows
      ((,) <$> field <*> monitorRow)
      "SELECT monitor_id,monitor_ordinal,legacy_group_id,definition_revision,status,task_profile,change_only,overlap_policy,queue_limit,next_fire_at,\
      \ (SELECT count(*) FROM monitor_fires WHERE monitor_id=definition.monitor_id AND disposition='coalesced'),\
      \ (SELECT count(*) FROM monitor_fires WHERE monitor_id=definition.monitor_id AND disposition='overflow'),\
      \ (SELECT last_error FROM monitor_fires WHERE monitor_id=definition.monitor_id ORDER BY fire_id DESC LIMIT 1)\
      \ FROM monitors definition JOIN conversations USING(conversation_id) ORDER BY monitor_id DESC LIMIT 500"
      ()
  active <- case monitors of
    [] -> pure []
    _ ->
      queryRows
        ((,) <$> field <*> (ActiveTask <$> field <*> enumField parseTaskStatus))
        "SELECT fire.monitor_id,work.task_id,work.status FROM monitor_fires fire JOIN durable_tasks work ON work.task_id=fire.task_id\
        \ WHERE fire.monitor_id=ANY(?) AND work.status IN ('queued','running','waiting','retrying') ORDER BY work.task_id"
        (Only (PGArray (map fst monitors)))
  requests <- query "SELECT count(*) FROM conversation_requests WHERE disposition IN ('pending','delegated','waiting','failed')" ()
  let byMonitor = foldr (\(identifier, task) -> Map.insertWith (<>) identifier [task]) Map.empty active
      views = [monitor {activeTasks = Map.findWithDefault [] identifier byMonitor} | (identifier :: Int64, monitor) <- monitors]
  case requests of
    [Only count] -> pure (WorkOverview tasks views count)
    _ -> error "durable work request aggregate missing"

taskRow :: RowParser TaskOverview
taskRow = TaskOverview <$> field <*> field <*> field <*> field <*> enumField parseTaskStatus <*> enumField parseProfile <*> field <*> field <*> field <*> field <*> field <*> field <*> field <*> field <*> field <*> field <*> field <*> field

monitorRow :: RowParser MonitorOverview
monitorRow = MonitorOverview <$> field <*> field <*> field <*> enumField parseMonitorStatus <*> enumField parseProfile <*> field <*> enumField parseOverlapPolicy <*> field <*> field <*> field <*> field <*> field <*> pure []
