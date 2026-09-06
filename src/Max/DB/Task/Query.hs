-- | Scoped, bounded task queries. No SQL constructs public handles, prose or
-- presentation JSON. Multi-query details share a read snapshot.
module Max.DB.Task.Query (listTasks, readTask) where

import Data.Int (Int64)
import Data.Maybe (listToMaybe)
import Database.PostgreSQL.Simple.FromRow (RowParser, field)
import Database.PostgreSQL.Simple.Types (Only (..))
import Effectful
import Effectful.PostgreSQL (WithConnection)
import Max.Browser.State (parseWorkspaceState)
import Max.DB.Codec (enumField, integralField, jsonField, queryRows)
import Max.DB.Transaction (withReadSnapshot)
import Max.Task.Query
import Max.Task.State (parseTaskStatus)
import Max.Task.Types (parseProfile)
import OneBot.Types (GroupId (..))

summaryRow :: RowParser TaskSummary
summaryRow = TaskSummary <$> field <*> field <*> field <*> enumField parseTaskStatus <*> field <*> field <*> field

listTasks :: (WithConnection :> es, IOE :> es) => GroupId -> Eff es [TaskSummary]
listTasks (GroupId group) =
  queryRows
    summaryRow
    "SELECT task_id,revision,left(objective,1500),status,owner_principal_id,parent_task_id,deadline\
    \ FROM durable_tasks JOIN conversations USING(conversation_id) WHERE legacy_group_id=? ORDER BY task_id DESC LIMIT 150"
    (Only group)

readTask :: (WithConnection :> es, IOE :> es) => GroupId -> Int64 -> Eff es (Maybe TaskDetails)
readTask (GroupId group) identifier = withReadSnapshot $ do
  tasks <-
    queryRows
      coreRow
      "SELECT task_id,revision,objective,status,owner_principal_id,parent_task_id,deadline,\
      \ profile,grants::text,COALESCE(result,'null'::jsonb)::text,calls_reserved,max_calls,rounds_reserved,\
      \ retry_count,next_attempt_at,last_error,attempt,\
      \ (SELECT count(*) FROM task_events WHERE task_id=work.task_id AND event_id>work.consumed_event)\
      \ FROM durable_tasks work JOIN conversations USING(conversation_id) WHERE legacy_group_id=? AND task_id=?"
      (group, identifier)
  case tasks of
    [core] -> do
      browser <-
        listToMaybe
          <$> queryRows
            browserRow
            "SELECT state,generation,epoch,owner_turn_id,checkpoint_at,last_used_at FROM browser_workspaces WHERE task_id=?"
            (Only identifier)
      progress <-
        listToMaybe
          <$> queryRows
            progressRow
            "SELECT revision,attempt,version,body::text,updated_at FROM task_progress WHERE task_id=? AND revision=?"
            (identifier, core.summary.revision)
      turns <-
        queryRows
          field
          "SELECT turn_ordinal FROM task_attempts JOIN agent_turns USING(turn_id) WHERE task_id=? ORDER BY attempt LIMIT 40"
          (Only identifier)
      usage <-
        queryRows
          (TaskUsage <$> integralField <*> integralField)
          "SELECT COALESCE(sum(prompt_tokens),0),COALESCE(sum(completion_tokens),0) FROM task_attempts JOIN agent_turns USING(turn_id) WHERE task_id=?"
          (Only identifier)
      events <-
        queryRows
          eventRow
          "SELECT event_id,revision,kind,author_principal_id,source_message_id,left(body,10000)\
          \ FROM task_events WHERE task_id=? ORDER BY event_id DESC LIMIT 60"
          (Only identifier)
      case usage of
        [total] -> pure (Just (TaskDetails core browser progress turns total events))
        _ -> error "task usage aggregate missing"
    _ -> pure Nothing
  where
    coreRow =
      TaskCore
        <$> summaryRow
        <*> enumField parseProfile
        <*> jsonField
        <*> jsonField
        <*> field
        <*> field
        <*> field
        <*> field
        <*> field
        <*> field
        <*> field
        <*> field
    browserRow = BrowserView <$> enumField parseWorkspaceState <*> field <*> field <*> field <*> field <*> field
    progressRow = ProgressView <$> field <*> field <*> field <*> jsonField <*> field
    eventRow = EventView <$> field <*> field <*> field <*> field <*> field <*> field
