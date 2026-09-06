module Max.DB.Task
  ( TaskExecution (..),
    admitTask,
    admitTaskReceipt,
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
    taskReportTyped,
    recordTaskProgress,
    finishRequest,
    finishRequestTyped,
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
    steerChildTyped,
    durableWorkOverview,
  )
where

import Control.Monad (forM, void)
import Data.Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (parseEither)
import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime, addUTCTime)
import Database.PostgreSQL.Simple.FromRow (FromRow (..), field)
import Database.PostgreSQL.Simple.Types (Only (..))
import Effectful
import Effectful.PostgreSQL (WithConnection, execute, query)
import Max.DB.Codec (jsonField)
import Max.DB.Monitor.Admission qualified as MonitorAdmission
import Max.DB.Task.Admission qualified as Admission
import Max.DB.Task.Authorization qualified as Authorization
import Max.DB.Task.Control qualified as Control
import Max.DB.Task.MonitorControl qualified as MonitorControl
import Max.DB.Task.Overview qualified as Overview
import Max.DB.Task.Query qualified as Query
import Max.DB.Task.Record qualified as Record
import Max.DB.Task.Reporting qualified as Reporting
import Max.DB.Task.Scheduling qualified as Scheduling
import Max.DB.Transaction (withTransaction)
import Max.Execution.Types (ExecutionStep)
import Max.Monitor.Control (PendingPolicy, monitorControlErrorText, parsePendingPolicy)
import Max.Monitor.Policy (OverlapPolicy, parseOverlapPolicy)
import Max.Monitor.Types (MonitorFireId (..))
import Max.Platform.Types (CanonicalMessageId (..), PrincipalId (..))
import Max.Task.Admission (AdmissionError, TaskAdmissionReceipt (..), admissionErrorText)
import Max.Task.Policy (frontendLeaseSeconds)
import Max.Task.State qualified as State
import Max.Task.Types (TaskProfile (..), parseProfile, profileName)
import Max.Task.View
import Max.Turn.Types (AgentTurnId (..), AgentTurnRef (..))
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
    teHistory :: !TaskHistory
  }
  deriving stock (Show, Eq)

admitTask :: (WithConnection :> es, IOE :> es) => AgentTurnRef -> CanonicalMessageId -> PrincipalId -> Text -> Text -> TaskProfile -> Value -> Map Text Text -> Eff es Value
admitTask turn (CanonicalMessageId message) (PrincipalId principal) key objective profile inputs grants = withTransaction $ do
  admitted <- Admission.admitTaskWithin turn.atrTurnId (if message > 0 then Just message else Nothing) principal key objective profile inputs grants
  pure $ case admitted of
    Left failure -> object ["error" .= admissionErrorText failure]
    Right task ->
      object
        [ "task_id" .= task.taskId,
          "revision" .= task.revision,
          "objective" .= task.objective,
          "status" .= task.status,
          "profile" .= profileName task.profile,
          "inputs" .= task.inputs,
          "grants" .= task.grants,
          "owner_principal_id" .= task.owner,
          "source_message_id" .= task.sourceMessage,
          "parent_task_id" .= task.parent,
          "root_task_id" .= task.root,
          "deadline" .= task.deadline,
          "calls_reserved" .= task.calls,
          "rounds_reserved" .= task.rounds,
          "max_calls" .= task.maxCalls,
          "max_rounds" .= task.maxRounds,
          "attempt" .= task.attempt
        ]

-- | The tool runner receives a typed receipt from the committed record.
admitTaskReceipt :: (WithConnection :> es, IOE :> es) => AgentTurnRef -> CanonicalMessageId -> PrincipalId -> Text -> Text -> TaskProfile -> Value -> Map Text Text -> Eff es (Either AdmissionError TaskAdmissionReceipt)
admitTaskReceipt turn (CanonicalMessageId message) (PrincipalId principal) key objective profile inputs grants = withTransaction $ do
  result <- Admission.admitTaskWithin turn.atrTurnId (if message > 0 then Just message else Nothing) principal key objective profile inputs grants
  pure (receipt <$> result)
  where
    receipt (task :: Record.TaskRecord) = TaskAdmissionReceipt task.taskId task.revision task.status task.profile task.deadline task.maxCalls task.maxRounds task.grants

taskControl :: (WithConnection :> es, IOE :> es) => GroupId -> PrincipalId -> Bool -> Int64 -> Text -> Maybe Int -> Maybe CanonicalMessageId -> Text -> Eff es Value
taskControl (GroupId group) (PrincipalId principal) administrator identifier operation revision source note = withTransaction $
  case State.parseTaskOperation operation of
    Nothing -> pure (object ["error" .= ("invalid task operation" :: Text)])
    Just command -> renderControl <$> Control.controlTask group principal administrator identifier command revision ((.unCanonicalMessageId) <$> source) note

renderControl :: Either State.TaskControlError State.TaskControlReceipt -> Value
renderControl = \case
  Right receipt -> toJSON receipt
  Left failure -> object $ ["error" .= State.renderTaskControlError failure] <> ["revision" .= current | State.TaskRevisionConflict current <- [failure]]

listDurableTasks :: (WithConnection :> es, IOE :> es) => GroupId -> Eff es Value
listDurableTasks group = toJSON <$> Query.listTasks group

taskStatus :: (WithConnection :> es, IOE :> es) => GroupId -> Int64 -> Eff es Value
taskStatus group identifier = maybe (object ["error" .= ("not found in this conversation" :: Text)]) toJSON <$> Query.readTask group identifier

claimTask :: (WithConnection :> es, IOE :> es) => Text -> Eff es [AgentTurnId]
claimTask = Scheduling.claimTask

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

newtype ExecutionRow = ExecutionRow TaskExecution

instance FromRow ExecutionRow where
  fromRow =
    ExecutionRow
      <$> ( TaskExecution
              <$> field
              <*> field
              <*> (AgentTurnRef <$> field <*> field)
              <*> (GroupId <$> field)
              <*> (PrincipalId <$> field)
              <*> (CanonicalMessageId <$> field)
              <*> field
              <*> field
              <*> jsonField
              <*> jsonField
              <*> field
              <*> pure (TaskHistory Nothing [])
          )

loadTaskExecution :: (WithConnection :> es, IOE :> es) => AgentTurnId -> Eff es (Maybe TaskExecution)
loadTaskExecution turn = withTransaction $ do
  rows <-
    query
      "SELECT work.task_id,work.revision,execution.turn_id,current_turn.turn_ordinal,conversation.legacy_group_id,\
      \ work.owner_principal_id,COALESCE(work.source_message_id,source.trigger_canonical_message_id,0),\
      \ work.objective,work.profile,work.inputs::text,work.grants::text,work.deadline\
      \ FROM task_attempts execution JOIN durable_tasks work USING(task_id) JOIN conversations conversation USING(conversation_id)\
      \ JOIN agent_turns source ON source.turn_id=work.source_turn_id JOIN agent_turns current_turn ON current_turn.turn_id=execution.turn_id\
      \ WHERE execution.turn_id=? AND execution.revision=work.revision AND execution.attempt=work.attempt AND work.status='running'"
      (Only turn)
  case rows of
    [ExecutionRow execution] -> do
      progressRows <- query "SELECT body FROM task_progress WHERE task_id=? AND revision=?" (execution.teTaskId, execution.teRevision)
      previous <-
        query
          "SELECT previous.turn_id,previous.attempt,previous.revision,previous.report FROM task_attempts previous\
          \ WHERE previous.task_id=? AND previous.attempt<(SELECT attempt FROM task_attempts WHERE turn_id=?)\
          \ ORDER BY previous.attempt DESC LIMIT 15"
          (execution.teTaskId, turn)
      attempts <- forM previous $ \(previousTurn, attempt, revision, report) -> do
        journal <-
          query
            "SELECT tool_ref,state,COALESCE(result_preview,failure_detail,'') FROM (\
            \ SELECT execution_ordinal,tool_ref,state,result_preview,failure_detail FROM execution_journal\
            \ WHERE turn_id=? ORDER BY execution_ordinal DESC LIMIT 100) recent ORDER BY execution_ordinal"
            (Only (previousTurn :: AgentTurnId))
        pure (AttemptHistory attempt revision report [JournalHistory tool state preview | (tool, state, preview) <- journal])
      observations <-
        query
          "SELECT fire_id,left(trigger_evidence,5000) FROM monitor_fires\
          \ WHERE coalesced_into=(SELECT monitor_fire_id FROM durable_tasks WHERE task_id=?)\
          \ AND created_at>(SELECT created_at FROM durable_tasks WHERE task_id=?) ORDER BY fire_id DESC LIMIT 80"
          (execution.teTaskId, execution.teTaskId)
      let late = [object ["fire_id" .= fire, "evidence" .= (evidence :: Text)] | (fire, evidence) <- observations :: [(Int64, Text)]]
          inputs = case execution.teInputs of
            Object values -> Object (KeyMap.insert "late_coalesced_occurrences" (if null late then Null else toJSON late) values)
            value -> value
          progress = case progressRows of [Only value] -> Just value; _ -> Nothing
      pure (Just execution {teInputs = inputs, teHistory = TaskHistory progress attempts})
    _ -> pure Nothing

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

authorizeTaskStep :: (WithConnection :> es, IOE :> es) => AgentTurnId -> ExecutionStep -> Eff es Bool
authorizeTaskStep turn step = withTransaction $ Authorization.authorizeWithin turn step

taskInbox :: (WithConnection :> es, IOE :> es) => AgentTurnId -> Eff es Text
taskInbox turn = withTransaction $ do
  _ <- Record.lockTurnConversation turn
  owned <- Authorization.authorizeWithin turn Authorization.ExecutionCheckpoint
  _ <- Record.loadAttempt turn
  rows <-
    query
      "SELECT event.event_id,event.kind,event.author_principal_id,event.body\
      \ FROM task_events event JOIN durable_tasks work USING(task_id) JOIN task_attempts attempt USING(task_id)\
      \ WHERE ? AND attempt.turn_id=? AND attempt.revision=work.revision AND attempt.attempt=work.attempt\
      \ AND event.event_id>GREATEST(work.consumed_event,attempt.seen_event) ORDER BY event.event_id LIMIT 80"
      (owned, turn)
  let events = [TaskEventView identifier kind principal body | (identifier, kind, principal, body) <- rows]
  case reverse events of
    [] -> pure ()
    event : _ ->
      void $
        execute
          "UPDATE task_attempts attempt SET seen_event=GREATEST(seen_event,?) FROM durable_tasks work\
          \ WHERE attempt.turn_id=? AND attempt.task_id=work.task_id AND attempt.revision=work.revision AND attempt.attempt=work.attempt"
          (event.eventId, turn)
  pure (renderTaskInbox events)

taskReport :: (WithConnection :> es, IOE :> es) => AgentTurnId -> Value -> Eff es Bool
taskReport turn report = case State.parseTaskReport report of
  Left _ -> pure False
  Right typed -> taskReportTyped turn typed

taskReportTyped :: (WithConnection :> es, IOE :> es) => AgentTurnId -> State.TaskReport -> Eff es Bool
taskReportTyped = Reporting.submitReport

claimFrontend :: (WithConnection :> es, IOE :> es) => AgentTurnRef -> Eff es Bool
claimFrontend turn = withTransaction $ do
  _ <- Record.lockTurnConversation turn.atrTurnId
  active <-
    query
      "SELECT conversation_id,trigger_canonical_message_id FROM agent_turns WHERE turn_id=? AND status IN ('starting','running','recovery-pending') FOR UPDATE"
      (Only turn.atrTurnId)
  case active :: [(Int64, Maybe Int64)] of
    [(conversation, trigger)] -> do
      occupied <-
        query
          "SELECT EXISTS(SELECT 1 FROM conversation_frontends WHERE conversation_id=? AND turn_id<>? AND lease_until>clock_timestamp())"
          (conversation, turn.atrTurnId)
      if occupied == [Only True]
        then pure False
        else do
          now <- Record.databaseNow
          void $
            execute
              "INSERT INTO conversation_frontends(conversation_id,turn_id,lease_until) VALUES(?,?,?) ON CONFLICT(conversation_id) DO UPDATE SET turn_id=excluded.turn_id,lease_until=excluded.lease_until"
              (conversation, turn.atrTurnId, addUTCTime (fromIntegral frontendLeaseSeconds) now)
          void $ execute "UPDATE agent_turns SET frontend_managed=true WHERE turn_id=?" (Only turn.atrTurnId)
          void $
            execute
              "INSERT INTO conversation_requests(message_id,turn_id) SELECT ?,? WHERE ?::bigint IS NOT NULL AND NOT EXISTS(SELECT 1 FROM task_notifications WHERE turn_id=?) ON CONFLICT(message_id) DO UPDATE SET turn_id=excluded.turn_id WHERE conversation_requests.disposition='pending'"
              (trigger, turn.atrTurnId, trigger, turn.atrTurnId)
          pure True
    _ -> pure False

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
      \ work.task_id,notice.revision,notice.body,work.grants::text\
      \ FROM task_notifications notice JOIN durable_tasks work USING(task_id) JOIN conversations conversation USING(conversation_id)\
      \ JOIN agent_turns source ON source.turn_id=work.source_turn_id WHERE notice.turn_id=? AND notice.superseded_at IS NULL AND notice.revision=work.revision AND notice.attempt=work.attempt AND notice.body->>'status'=work.status AND work.status<>'cancelled'"
      (Only turn)
  pure $ case rows of
    [(group, seed, task, revision, body, grants)] -> case eitherDecodeStrict' (TE.encodeUtf8 grants) of
      Right decoded -> Just (GroupId group, CanonicalMessageId seed, renderTaskNotification task revision body, decoded)
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
admitMonitorTask owner fire next grants (CanonicalMessageId seed) = withTransaction $ do
  result <- MonitorAdmission.admitMonitorTaskWithin owner fire next grants seed
  pure $ case result of
    Right (MonitorAdmission.MonitorTaskAdmitted identifier) -> object ["task_id" .= identifier]
    Right (MonitorAdmission.MonitorCoalesced target) -> object ["disposition" .= ("coalesced" :: Text), "coalesced_into" .= target]
    Right MonitorAdmission.MonitorOverflow -> object ["disposition" .= ("overflow" :: Text)]
    Left failure -> object ["error" .= monitorAdmissionErrorText failure]

monitorAdmissionErrorText :: MonitorAdmission.MonitorAdmissionError -> Text
monitorAdmissionErrorText = \case
  MonitorAdmission.OccurrenceClaimLost -> "occurrence claim lost"
  MonitorAdmission.MonitorAuthorityUnavailable -> "monitor authority unavailable"
  MonitorAdmission.MonitorAuthorityWidened -> "monitor authority widened"
  MonitorAdmission.MonitorHourlyBudget -> "monitor hourly admission budget"
  MonitorAdmission.InvalidDefinitionSnapshot -> "invalid monitor definition snapshot"

monitorControl :: (WithConnection :> es, IOE :> es) => GroupId -> PrincipalId -> Bool -> Int64 -> Text -> Maybe Int -> Text -> Text -> Int -> Text -> Bool -> Eff es Value
monitorControl (GroupId group) (PrincipalId actor) administrator ordinal operation revision objective overlap capacity pending cancelTasks =
  case operation of
    "cancel" -> runMonitorControl group actor administrator ordinal MonitorControl.CancelMonitor cancelTasks
    "configure" -> case (revision, parseMonitorPolicies overlap pending) of
      (Just expected, Just (coalesce, cancelPending)) -> runMonitorControl group actor administrator ordinal (MonitorControl.ConfigureMonitor expected objective coalesce capacity cancelPending Nothing) cancelTasks
      _ -> pure (object ["error" .= ("invalid monitor definition" :: Text)])
    _ -> pure (object ["error" .= ("invalid operation" :: Text)])

parseMonitorPolicies :: Text -> Text -> Maybe (OverlapPolicy, PendingPolicy)
parseMonitorPolicies overlap pending = (,) <$> parseOverlapPolicy overlap <*> parsePendingPolicy pending

runMonitorControl :: (WithConnection :> es, IOE :> es) => Int64 -> Int64 -> Bool -> Int64 -> MonitorControl.MonitorCommand -> Bool -> Eff es Value
runMonitorControl group actor administrator ordinal command cancelTasks = withTransaction $ do
  result <- MonitorControl.controlMonitor group actor administrator ordinal command cancelTasks
  pure $ either (\failure -> object ["error" .= monitorControlErrorText failure]) toJSON result

monitorHistory :: (WithConnection :> es, IOE :> es) => GroupId -> Int64 -> Eff es Value
monitorHistory group ordinal = maybe (object ["error" .= ("not found in this conversation" :: Text)]) toJSON <$> Overview.readMonitorHistory group ordinal

taskResource :: (WithConnection :> es, IOE :> es) => AgentTurnId -> Text -> Eff es Bool
taskResource turn resource = withTransaction $ Authorization.reserveResourceWithin turn resource

steerChild :: (WithConnection :> es, IOE :> es) => AgentTurnId -> Int64 -> Text -> Eff es Value
steerChild turn identifier note = renderControl <$> steerChildTyped turn identifier note

steerChildTyped :: (WithConnection :> es, IOE :> es) => AgentTurnId -> Int64 -> Text -> Eff es (Either State.TaskControlError State.TaskControlReceipt)
steerChildTyped turn identifier note = withTransaction $ do
  _ <- Record.lockTurnConversation turn
  authorized <- Authorization.authorizeWithin turn Authorization.ExecutionCheckpoint
  parents <-
    query
      "SELECT source.initiator_principal_id,conversation.legacy_group_id FROM durable_tasks child JOIN task_attempts parent ON child.parent_task_id=parent.task_id AND child.parent_revision=parent.revision JOIN agent_turns source USING(turn_id) JOIN conversations conversation ON conversation.conversation_id=source.conversation_id WHERE parent.turn_id=? AND child.task_id=?"
      (turn, identifier)
  case parents of
    [(actor, group)] | authorized -> Control.controlTask group actor False identifier State.Steer Nothing Nothing note
    _ -> pure (Left (if authorized then State.TaskChildScopeRequired else State.TaskCallerFenced))

durableWorkOverview :: (WithConnection :> es, IOE :> es) => Eff es Value
durableWorkOverview = toJSON <$> Overview.readWorkOverview

recordTaskProgress :: (WithConnection :> es, IOE :> es) => AgentTurnId -> Value -> Eff es Bool
recordTaskProgress turn progress = case parseEither (withObject "task progress" (.: "summary")) progress of
  Left _ -> pure False
  Right summary -> Reporting.submitProgress turn summary

finishRequest :: (WithConnection :> es, IOE :> es) => AgentTurnId -> Text -> Text -> Eff es Bool
finishRequest turn disposition reply = case State.parseDisposition disposition of
  Nothing -> pure False
  Just typed -> finishRequestTyped turn typed reply

finishRequestTyped :: (WithConnection :> es, IOE :> es) => AgentTurnId -> State.RequestDisposition -> Text -> Eff es Bool
finishRequestTyped = Reporting.submitRequest

recordTaskFailure :: (WithConnection :> es, IOE :> es) => AgentTurnId -> Text -> State.FailureKind -> Eff es Bool
recordTaskFailure = Reporting.submitFailure

notificationKind :: (WithConnection :> es, IOE :> es) => AgentTurnId -> Eff es (Maybe Text)
notificationKind turn = do
  rows <- query "SELECT kind FROM task_notifications WHERE turn_id=? AND superseded_at IS NULL" (Only turn)
  pure $ case rows of [Only kind] -> Just kind; _ -> Nothing

monitorTaskProfile :: (WithConnection :> es, IOE :> es) => MonitorFireId -> Eff es TaskProfile
monitorTaskProfile fire = do
  rows <- query "SELECT COALESCE(definition_snapshot->>'profile',task_profile) FROM monitor_fires JOIN monitors USING(monitor_id) WHERE fire_id=?" (Only fire)
  pure $ case rows of [Only profile] -> fromMaybe Research (parseProfile profile); _ -> Research

configureMonitor :: (WithConnection :> es, IOE :> es) => GroupId -> PrincipalId -> Bool -> Int64 -> Int -> Text -> Text -> Int -> Text -> Text -> Bool -> Eff es Value
configureMonitor (GroupId group) (PrincipalId actor) administrator ordinal revision objective overlap capacity pending profile changeOnly =
  case (parseMonitorPolicies overlap pending, parseProfile profile) of
    (Just (coalesce, cancelPending), Just capability) -> do
      result <- runMonitorControl group actor administrator ordinal (MonitorControl.ConfigureMonitor revision objective coalesce capacity cancelPending (Just (capability, changeOnly))) False
      pure $ case result of
        Object fields -> Object (KeyMap.insert "profile" (String profile) (KeyMap.insert "change_only" (Bool changeOnly) fields))
        value -> value
    _ -> pure (object ["error" .= ("invalid monitor definition" :: Text)])

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
