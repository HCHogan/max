module Max.DB.Task
  ( TaskExecution (..),
    admitTask,
    taskControl,
    listDurableTasks,
    taskStatus,
    claimTask,
    nextTaskWakeMicros,
    fencedTaskTurns,
    loadTaskExecution,
    isTaskTurn,
    renewTask,
    authorizeTaskStep,
    taskInbox,
    taskReport,
    recordTaskProgress,
    finishRequest,
    recordTaskFailure,
    notificationKind,
    monitorTaskProfile,
    configureMonitor,
    claimFrontend,
    admitTaskNotification,
    loadTaskNotification,
    taskTurnRef,
    taskForReply,
    admitMonitorTask,
    monitorControl,
    monitorHistory,
    taskResource,
    steerChild,
    durableWorkOverview,
  )
where

import Control.Monad (void)
import Data.Aeson
import Data.Aeson.Types (parseEither)
import Data.ByteString.Lazy qualified as LBS
import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime)
import Database.PostgreSQL.Simple.Types (Only (..))
import Effectful
import Effectful.PostgreSQL (WithConnection, execute, query)
import Max.DB.Transaction (withTransaction)
import Max.Monitor.Types (MonitorFireId (..))
import Max.Platform.Types (CanonicalMessageId (..), PrincipalId (..))
import Max.Task.Types (TaskProfile (..), parseProfile, profileName)
import Max.Turn.Types (AgentTurnId (..), AgentTurnRef (..), TurnOrdinal (..))
import OneBot.Types (GroupId (..))

data TaskExecution = TaskExecution
  { teTaskId :: !Int64,
    teRevision :: !Int,
    teTurn :: !AgentTurnRef,
    teGroup :: !GroupId,
    tePrincipal :: !PrincipalId,
    teSeed :: !CanonicalMessageId,
    teObjective :: !Text,
    teProfile :: !Text,
    teInputs :: !Value,
    teGrants :: !(Map Text Text),
    teDeadline :: !UTCTime,
    teHistory :: !Text
  }
  deriving stock (Show, Eq)

admitTask :: (WithConnection :> es, IOE :> es) => AgentTurnRef -> CanonicalMessageId -> PrincipalId -> Text -> Text -> TaskProfile -> Value -> Map Text Text -> Eff es Value
admitTask turn (CanonicalMessageId message) (PrincipalId principal) key objective profile inputs grants = do
  rows <-
    query
      "SELECT max_task_admit(?,?,?,?,?,?,?::jsonb,?::jsonb)::text"
      (turn.atrTurnId, if message > 0 then Just message else Nothing, principal, key, objective, profileName profile, encoded inputs, encoded (toJSON grants))
  decodeRow rows

taskControl :: (WithConnection :> es, IOE :> es) => GroupId -> PrincipalId -> Bool -> Int64 -> Text -> Maybe Int -> Maybe CanonicalMessageId -> Text -> Eff es Value
taskControl (GroupId group) (PrincipalId principal) administrator identifier operation revision source note = do
  rows <-
    query
      "SELECT max_task_control(?,?,?,?,?,?,?,?)::text"
      (group, principal, administrator, identifier, operation, revision, (.unCanonicalMessageId) <$> source, note)
  decodeRow rows

listDurableTasks :: (WithConnection :> es, IOE :> es) => GroupId -> Eff es Value
listDurableTasks (GroupId group) = do
  rows <-
    query
      "SELECT COALESCE(jsonb_agg(summary ORDER BY task_id DESC),'[]'::jsonb)::text FROM (\
      \ SELECT work.task_id,jsonb_build_object('task', 'task#'||work.task_id,'revision',revision,'objective',left(objective,1500),\
      \ 'status',status,'owner',owner_principal_id,'parent',parent_task_id,'deadline',deadline) AS summary\
      \ FROM durable_tasks work JOIN conversations USING(conversation_id) WHERE legacy_group_id=? ORDER BY task_id DESC LIMIT 150) recent"
      (Only group)
  decodeRow rows

taskStatus :: (WithConnection :> es, IOE :> es) => GroupId -> Int64 -> Eff es Value
taskStatus (GroupId group) identifier = do
  rows <-
    query
      "SELECT jsonb_build_object('task','task#'||work.task_id,'revision',revision,'objective',objective,'status',status,\
      \ 'owner',owner_principal_id,'parent',parent_task_id,'profile',profile,'effective_tools',grants,\
      \ 'result',result,'calls_reserved',calls_reserved,'max_calls',max_calls,'rounds_reserved',rounds_reserved,\
      \ 'retry_count',retry_count,'next_attempt_at',next_attempt_at,'last_error',last_error,\
      \ 'progress',(SELECT jsonb_build_object('revision',revision,'attempt',attempt,'version',version,'body',body,'updated_at',updated_at) FROM task_progress WHERE task_id=work.task_id AND revision=work.revision),\
      \ 'deadline',deadline,'attempts',attempt,'pending_events',(SELECT count(*) FROM task_events WHERE task_id=work.task_id AND event_id>consumed_event),\
      \ 'turns',(SELECT jsonb_agg('t#'||turn.turn_ordinal ORDER BY execution.attempt) FROM task_attempts execution JOIN agent_turns turn USING(turn_id) WHERE execution.task_id=work.task_id),\
      \ 'usage',(SELECT jsonb_build_object('prompt_tokens',COALESCE(sum(turn.prompt_tokens),0),\
      \ 'completion_tokens',COALESCE(sum(turn.completion_tokens),0),'accounting','observational; missing provider usage is unknown, not zero')\
      \ FROM task_attempts execution JOIN agent_turns turn USING(turn_id) WHERE execution.task_id=work.task_id),\
      \ 'events',(SELECT COALESCE(jsonb_agg(event),'[]') FROM (SELECT event_id,revision,kind,author_principal_id,source_message_id,left(body,10000) AS body\
      \ FROM task_events WHERE task_id=work.task_id ORDER BY event_id DESC LIMIT 60) event))::text\
      \ FROM durable_tasks work JOIN conversations USING(conversation_id) WHERE legacy_group_id=? AND work.task_id=?"
      (group, identifier)
  decodeRow rows

claimTask :: (WithConnection :> es, IOE :> es) => Text -> Eff es [AgentTurnId]
claimTask owner = do
  rows <- query "SELECT max_task_claim(?)" (Only owner)
  pure [turn | Only (Just turn) <- rows]

fencedTaskTurns :: (WithConnection :> es, IOE :> es) => Eff es [AgentTurnId]
fencedTaskTurns = do
  rows <-
    query
      "SELECT execution.turn_id FROM task_attempts execution JOIN durable_tasks work USING(task_id) JOIN agent_turns turn USING(turn_id)\
      \ WHERE (turn.status IN ('starting','running','recovery-pending') OR turn.status='crashed' AND turn.abort_reason='task execution lease expired')\
      \ AND (work.status<>'running' OR work.revision<>execution.revision OR work.attempt<>execution.attempt OR execution.lease_until<=clock_timestamp())\
      \ ORDER BY execution.turn_id DESC LIMIT 640"
      ()
  pure [turn | Only turn <- rows]

isTaskTurn :: (WithConnection :> es, IOE :> es) => AgentTurnId -> Eff es Bool
isTaskTurn turn = do
  rows <- query "SELECT EXISTS (SELECT 1 FROM task_attempts WHERE turn_id=?)" (Only turn)
  pure (rows == [Only True])

loadTaskExecution :: (WithConnection :> es, IOE :> es) => AgentTurnId -> Eff es (Maybe TaskExecution)
loadTaskExecution turn = do
  rows <-
    query
      "SELECT jsonb_build_object('task_id',work.task_id,'revision',work.revision,'turn_id',execution.turn_id,\
      \ 'ordinal',current_turn.turn_ordinal,'group',conversation.legacy_group_id,'principal',work.owner_principal_id,\
      \ 'seed',COALESCE(work.source_message_id,source.trigger_canonical_message_id,0),'objective',work.objective,\
      \ 'profile',work.profile,'inputs',work.inputs || jsonb_build_object('late_coalesced_occurrences',\
      \ (SELECT jsonb_agg(event) FROM (SELECT fire_id,left(trigger_evidence,5000) AS evidence FROM monitor_fires\
      \ WHERE coalesced_into=work.monitor_fire_id AND created_at>work.created_at ORDER BY fire_id DESC LIMIT 80) event)),\
      \ 'grants',work.grants,'deadline',work.deadline,\
      \ 'history',COALESCE((SELECT 'latest progress: '||body::text||E'\\n' FROM task_progress WHERE task_id=work.task_id AND revision=work.revision),'')||COALESCE((SELECT string_agg(entry,E'\\n' ORDER BY attempt DESC) FROM (\
      \ SELECT previous.attempt,'attempt '||previous.attempt||' revision '||previous.revision||': '||\
      \ COALESCE(previous.report::text,'no committed report; inspect journal before repeating effects')||E'\\n'||\
      \ COALESCE((SELECT string_agg(tool_ref||' ['||state||'] '||COALESCE(result_preview,failure_detail,''),E'\\n' ORDER BY execution_ordinal)\
      \ FROM (SELECT * FROM execution_journal WHERE turn_id=previous.turn_id ORDER BY execution_ordinal DESC LIMIT 100) journal),'') AS entry\
      \ FROM task_attempts previous WHERE previous.task_id=work.task_id AND previous.attempt<execution.attempt ORDER BY previous.attempt DESC LIMIT 15) prior),''))::text\
      \ FROM task_attempts execution JOIN durable_tasks work USING(task_id) JOIN conversations conversation USING(conversation_id)\
      \ JOIN agent_turns source ON source.turn_id=work.source_turn_id JOIN agent_turns current_turn ON current_turn.turn_id=execution.turn_id\
      \ WHERE execution.turn_id=? AND execution.revision=work.revision AND execution.attempt=work.attempt AND work.status='running'"
      (Only turn)
  case rows of
    [] -> pure Nothing
    _ -> do
      value <- decodeRow rows
      case parseEither parser value of
        Left detail -> error ("loadTaskExecution: " <> detail)
        Right execution -> pure (Just execution)
  where
    parser = withObject "task execution" $ \fields ->
      TaskExecution
        <$> fields .: "task_id"
        <*> fields .: "revision"
        <*> (AgentTurnRef . AgentTurnId <$> fields .: "turn_id" <*> (TurnOrdinal <$> fields .: "ordinal"))
        <*> (GroupId <$> fields .: "group")
        <*> (PrincipalId <$> fields .: "principal")
        <*> (CanonicalMessageId <$> fields .: "seed")
        <*> fields .: "objective"
        <*> fields .: "profile"
        <*> fields .: "inputs"
        <*> fields .: "grants"
        <*> fields .: "deadline"
        <*> fields .: "history"

renewTask :: (WithConnection :> es, IOE :> es) => AgentTurnId -> Eff es Bool
renewTask turn = do
  moved <-
    execute
      "UPDATE task_attempts execution SET lease_until=clock_timestamp()+interval '60 seconds'\
      \ FROM durable_tasks work WHERE execution.turn_id=? AND execution.task_id=work.task_id\
      \ AND execution.attempt=work.attempt AND execution.revision=work.revision AND work.status='running'\
      \ AND execution.lease_until>clock_timestamp() AND work.deadline>clock_timestamp()"
      (Only turn)
  pure (moved == 1)

authorizeTaskStep :: (WithConnection :> es, IOE :> es) => AgentTurnId -> Maybe Text -> Bool -> Eff es Bool
authorizeTaskStep turn tool reserve = do
  rows <- query "SELECT max_task_authorize(?,?,?)" (turn, tool, reserve)
  pure (rows == [Only True])

taskInbox :: (WithConnection :> es, IOE :> es) => AgentTurnId -> Eff es Text
taskInbox turn = do
  rows <- query "SELECT max_task_inbox(?)" (Only turn)
  pure $ case rows of [Only body] -> body; _ -> ""

taskReport :: (WithConnection :> es, IOE :> es) => AgentTurnId -> Value -> Eff es Bool
taskReport turn report = do
  rows <- query "SELECT max_task_report(?,?::jsonb)" (turn, encoded report)
  pure (rows == [Only True])

claimFrontend :: (WithConnection :> es, IOE :> es) => AgentTurnRef -> Eff es Bool
claimFrontend turn = do
  rows <- query "SELECT max_frontend_claim(?)" (Only turn.atrTurnId)
  pure (rows == [Only True])

admitTaskNotification :: (WithConnection :> es, IOE :> es) => Eff es [AgentTurnId]
admitTaskNotification = withTransaction $ do
  rows <-
    query
      "SELECT notice.notification_id,work.conversation_id,work.owner_principal_id,work.source_message_id\
      \ FROM task_notifications notice JOIN durable_tasks work USING(task_id) LEFT JOIN agent_turns turn ON turn.turn_id=notice.turn_id\
      \ WHERE notice.delivered_at IS NULL AND notice.superseded_at IS NULL AND notice.next_attempt_at<=clock_timestamp() AND notice.revision=work.revision AND notice.attempt=work.attempt AND notice.body->>'status'=work.status AND work.status<>'cancelled' AND notice.attempts<15\
      \ AND (notice.turn_id IS NULL OR turn.status IN ('failed','aborted','crashed','silence','succeeded'))\
      \ AND NOT EXISTS (SELECT 1 FROM conversation_frontends frontend WHERE frontend.conversation_id=work.conversation_id AND frontend.lease_until>clock_timestamp())\
      \ ORDER BY notice.notification_id LIMIT 1"
      ()
  case rows :: [(Int64, Int64, Int64, Maybe Int64)] of
    [(notification, conversation, principal, source)] -> do
      locked <- query "SELECT conversation_id FROM conversations WHERE conversation_id=? FOR UPDATE" (Only conversation)
      case locked :: [Only Int64] of
        [] -> error "admitTaskNotification: conversation missing"
        _ -> pure ()
      available <-
        query
          "SELECT notice.notification_id FROM task_notifications notice JOIN durable_tasks work USING(task_id)\
          \ LEFT JOIN agent_turns turn ON turn.turn_id=notice.turn_id WHERE notice.notification_id=?\
          \ AND notice.delivered_at IS NULL AND notice.superseded_at IS NULL AND notice.next_attempt_at<=clock_timestamp() AND notice.revision=work.revision AND notice.attempt=work.attempt\
          \ AND notice.body->>'status'=work.status AND work.status<>'cancelled' AND notice.attempts<15\
          \ AND (notice.turn_id IS NULL OR turn.status IN ('failed','aborted','crashed','silence','succeeded'))\
          \ AND NOT EXISTS (SELECT 1 FROM conversation_frontends frontend WHERE frontend.conversation_id=work.conversation_id AND frontend.lease_until>clock_timestamp())\
          \ FOR UPDATE OF notice"
          (Only notification)
      if null (available :: [Only Int64]) then pure [] else admitNotification notification conversation principal source
    _ -> pure []
  where
    admitNotification notification conversation principal source = do
      admitted <-
        query
          "INSERT INTO agent_turns(conversation_id,turn_ordinal,trigger_canonical_message_id,initiator_principal_id,status)\
          \ SELECT ?,COALESCE(max(turn_ordinal),0)+1,?,?,'starting' FROM agent_turns WHERE conversation_id=? RETURNING turn_id"
          (conversation, source, principal, conversation)
      case admitted of
        [Only turn] -> do
          void (execute "UPDATE task_notifications SET turn_id=?,attempts=attempts+1 WHERE notification_id=?" (turn, notification))
          void (execute "INSERT INTO task_output_turns(task_id,turn_id,revision,attempt) SELECT task_id,turn_id,revision,attempt FROM task_notifications WHERE notification_id=?" (Only notification))
          pure [turn]
        _ -> error "admitTaskNotification: no turn"

loadTaskNotification :: (WithConnection :> es, IOE :> es) => AgentTurnId -> Eff es (Maybe (GroupId, CanonicalMessageId, Text, Map Text Text))
loadTaskNotification turn = do
  rows <-
    query
      "SELECT conversation.legacy_group_id,COALESCE(work.source_message_id,source.trigger_canonical_message_id,0),\
      \ 'task#'||work.task_id||' revision '||notice.revision||E'\\n'||left(notice.body::text,80000),work.grants::text\
      \ FROM task_notifications notice JOIN durable_tasks work USING(task_id) JOIN conversations conversation USING(conversation_id)\
      \ JOIN agent_turns source ON source.turn_id=work.source_turn_id WHERE notice.turn_id=? AND notice.superseded_at IS NULL AND notice.revision=work.revision AND notice.attempt=work.attempt AND notice.body->>'status'=work.status AND work.status<>'cancelled'"
      (Only turn)
  pure $ case rows of
    [(group, seed, body, grants)] -> case eitherDecodeStrict' (TE.encodeUtf8 grants) of
      Right decoded -> Just (GroupId group, CanonicalMessageId seed, body, decoded)
      Left _ -> Nothing
    _ -> Nothing

taskTurnRef :: (WithConnection :> es, IOE :> es) => AgentTurnId -> Eff es (Maybe AgentTurnRef)
taskTurnRef turn = do
  rows <- query "SELECT turn_ordinal FROM agent_turns WHERE turn_id=?" (Only turn)
  pure $ case rows of [Only ordinal] -> Just (AgentTurnRef turn ordinal); _ -> Nothing

taskForReply :: (WithConnection :> es, IOE :> es) => GroupId -> CanonicalMessageId -> Eff es (Maybe Int64)
taskForReply (GroupId group) (CanonicalMessageId message) = do
  rows <-
    query
      "SELECT DISTINCT work.task_id FROM messages output JOIN conversations USING(conversation_id)\
      \ JOIN durable_tasks work ON work.conversation_id=output.conversation_id\
      \ AND (work.source_turn_id=output.agent_turn_id OR EXISTS (SELECT 1 FROM task_output_turns notice WHERE notice.task_id=work.task_id AND notice.turn_id=output.agent_turn_id))\
      \ WHERE legacy_group_id=? AND output.canonical_message_id=? LIMIT 2"
      (group, message)
  pure $ case rows of [Only identifier] -> Just identifier; _ -> Nothing

admitMonitorTask :: (WithConnection :> es, IOE :> es) => Text -> MonitorFireId -> Maybe UTCTime -> Map Text Text -> CanonicalMessageId -> Eff es Value
admitMonitorTask owner fire next grants (CanonicalMessageId seed) = do
  rows <- query "SELECT max_monitor_task_admit(?,?,?,?::jsonb,?)::text" (owner, fire, next, encoded (toJSON grants), seed)
  decodeRow rows

encoded :: Value -> Text
encoded = TE.decodeUtf8 . LBS.toStrict . encode

decodeRow :: (Applicative m) => [Only Text] -> m Value
decodeRow [Only raw] = case eitherDecodeStrict' (TE.encodeUtf8 raw) of
  Right value -> pure value
  Left detail -> error ("task store invalid JSON: " <> detail)
decodeRow _ = pure (object ["error" .= ("not found in this conversation" :: Text)])

monitorControl :: (WithConnection :> es, IOE :> es) => GroupId -> PrincipalId -> Bool -> Int64 -> Text -> Maybe Int -> Text -> Text -> Int -> Text -> Bool -> Eff es Value
monitorControl (GroupId group) (PrincipalId actor) administrator ordinal operation revision objective overlap capacity pending cancelTasks = do
  rows <-
    query
      "SELECT max_monitor_control(?,?,?,?,?,?,?,?,?,?,?)::text"
      (group, actor, administrator, ordinal, operation, revision, objective, overlap, capacity, pending, cancelTasks)
  decodeRow rows

monitorHistory :: (WithConnection :> es, IOE :> es) => GroupId -> Int64 -> Eff es Value
monitorHistory (GroupId group) ordinal = do
  rows <-
    query
      "SELECT jsonb_build_object('handle','m#'||monitor_ordinal,'revision',definition_revision,'goal',goal_text,'profile',task_profile,\
      \ 'status',status,'overlap',overlap_policy,'queue_limit',queue_limit,'change_only',change_only,'next_fire',next_fire_at,\
      \ 'fires',(SELECT COALESCE(jsonb_agg(entry),'[]') FROM (SELECT fire_id,definition_revision,scheduled_at,disposition,\
      \ task_id,coalesced_into,admission_state,left(trigger_evidence,5000) AS evidence,last_error FROM monitor_fires\
      \ WHERE monitor_id=definition.monitor_id ORDER BY fire_id DESC LIMIT 150) entry))::text\
      \ FROM monitors definition JOIN conversations USING(conversation_id) WHERE legacy_group_id=? AND monitor_ordinal=?"
      (group, ordinal)
  decodeRow rows

taskResource :: (WithConnection :> es, IOE :> es) => AgentTurnId -> Text -> Eff es Bool
taskResource turn resource = do
  rows <- query "SELECT max_task_resource(?,?)" (turn, resource)
  pure (rows == [Only True])

steerChild :: (WithConnection :> es, IOE :> es) => AgentTurnId -> Int64 -> Text -> Eff es Value
steerChild turn identifier note = do
  rows <- query "SELECT max_task_steer_child(?,?,?)::text" (turn, identifier, note)
  decodeRow rows

durableWorkOverview :: (WithConnection :> es, IOE :> es) => Eff es Value
durableWorkOverview = do
  rows <-
    query
      "SELECT jsonb_build_object('tasks',(SELECT COALESCE(jsonb_agg(entry),'[]') FROM (\
      \ SELECT 'task#'||task_id AS handle,legacy_group_id AS group_id,owner_principal_id,revision,status,profile,left(objective,1500) AS objective,\
      \ calls_reserved,max_calls,rounds_reserved,max_rounds,deadline,retry_count,next_attempt_at,last_error,\
      \ (SELECT body->>'summary' FROM task_progress WHERE task_id=durable_tasks.task_id AND revision=durable_tasks.revision) AS progress,\
      \ (SELECT count(*) FROM task_notifications WHERE task_id=durable_tasks.task_id AND revision=durable_tasks.revision AND attempt=durable_tasks.attempt AND superseded_at IS NULL AND delivered_at IS NULL AND attempts>=15) AS failed_notifications,\
      \ left(result::text,10000) AS result FROM durable_tasks JOIN conversations USING(conversation_id)\
      \ ORDER BY task_id DESC LIMIT 500) entry),\
      \ 'monitors',(SELECT COALESCE(jsonb_agg(entry),'[]') FROM (SELECT 'm#'||monitor_ordinal AS handle,legacy_group_id AS group_id,\
      \ definition_revision,status,task_profile,change_only,overlap_policy,queue_limit,next_fire_at,\
      \ (SELECT count(*) FROM monitor_fires WHERE monitor_id=definition.monitor_id AND disposition='coalesced') AS coalesced,\
      \ (SELECT count(*) FROM monitor_fires WHERE monitor_id=definition.monitor_id AND disposition='overflow') AS overflow,\
      \ (SELECT string_agg('task#'||work.task_id||' '||work.status,', ') FROM monitor_fires fire JOIN durable_tasks work ON work.task_id=fire.task_id\
      \ WHERE fire.monitor_id=definition.monitor_id AND work.status IN ('queued','running','waiting','retrying')) AS active_tasks,\
      \ (SELECT last_error FROM monitor_fires WHERE monitor_id=definition.monitor_id ORDER BY fire_id DESC LIMIT 1) AS last_error\
      \ FROM monitors definition JOIN conversations USING(conversation_id) ORDER BY monitor_id DESC LIMIT 500) entry),\
      \ 'unresolved_requests',(SELECT count(*) FROM conversation_requests WHERE disposition IN ('pending','delegated','waiting','failed')))::text"
      ()
  decodeRow rows

recordTaskProgress :: (WithConnection :> es, IOE :> es) => AgentTurnId -> Value -> Eff es Bool
recordTaskProgress turn progress = do
  rows <- query "SELECT max_task_progress(?,?::jsonb)" (turn, encoded progress)
  pure (rows == [Only True])

finishRequest :: (WithConnection :> es, IOE :> es) => AgentTurnId -> Text -> Text -> Eff es Bool
finishRequest turn disposition reply = do
  rows <- query "SELECT max_request_finish(?,?,?)" (turn, disposition, reply)
  pure (rows == [Only True])

recordTaskFailure :: (WithConnection :> es, IOE :> es) => AgentTurnId -> Text -> Bool -> Eff es Bool
recordTaskFailure turn detail retryable = do
  rows <- query "SELECT max_task_failure(?,?,?)" (turn, detail, retryable)
  pure (rows == [Only True])

notificationKind :: (WithConnection :> es, IOE :> es) => AgentTurnId -> Eff es (Maybe Text)
notificationKind turn = do
  rows <- query "SELECT kind FROM task_notifications WHERE turn_id=? AND superseded_at IS NULL" (Only turn)
  pure $ case rows of [Only kind] -> Just kind; _ -> Nothing

monitorTaskProfile :: (WithConnection :> es, IOE :> es) => MonitorFireId -> Eff es TaskProfile
monitorTaskProfile fire = do
  rows <- query "SELECT COALESCE(definition_snapshot->>'profile',task_profile) FROM monitor_fires JOIN monitors USING(monitor_id) WHERE fire_id=?" (Only fire)
  pure $ case rows of [Only profile] -> fromMaybe Research (parseProfile profile); _ -> Research

configureMonitor :: (WithConnection :> es, IOE :> es) => GroupId -> PrincipalId -> Bool -> Int64 -> Int -> Text -> Text -> Int -> Text -> Text -> Bool -> Eff es Value
configureMonitor (GroupId group) (PrincipalId actor) administrator ordinal revision objective overlap capacity pending profile changeOnly = do
  rows <- query "SELECT max_monitor_configure(?,?,?,?,?,?,?,?,?,?,?)::text" (group, actor, administrator, ordinal, revision, objective, overlap, capacity, pending, profile, changeOnly)
  decodeRow rows

nextTaskWakeMicros :: (WithConnection :> es, IOE :> es) => Eff es Int
nextTaskWakeMicros = do
  rows <-
    query
      "SELECT LEAST(30000000,GREATEST(50000,COALESCE(ceil(extract(epoch FROM min(wake_at)-clock_timestamp())*1000000),30000000)))::integer\
      \ FROM (SELECT next_attempt_at AS wake_at FROM durable_tasks WHERE status='retrying' AND next_attempt_at>clock_timestamp()\
      \ UNION ALL SELECT notice.next_attempt_at FROM task_notifications notice JOIN durable_tasks work USING(task_id)\
      \ WHERE notice.delivered_at IS NULL AND notice.superseded_at IS NULL AND notice.attempts<15\
      \ AND notice.revision=work.revision AND notice.attempt=work.attempt AND notice.body->>'status'=work.status\
      \ AND notice.next_attempt_at>clock_timestamp()\
      \ UNION ALL SELECT deadline FROM durable_tasks WHERE status IN ('queued','running','waiting','retrying') AND deadline>clock_timestamp()\
      \ UNION ALL SELECT execution.lease_until FROM task_attempts execution JOIN durable_tasks work USING(task_id)\
      \ WHERE work.status='running' AND execution.attempt=work.attempt AND execution.lease_until>clock_timestamp()) scheduled"
      ()
  pure $ case rows of [Only waitMicros] -> waitMicros; _ -> 30000000
