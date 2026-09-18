-- | Current-attempt reporting. Validation, progress coalescing and notification
-- spacing are host policies; every read and write shares one transaction.
module Max.DB.Task.Reporting (submitReport, submitReportChecked, submitProgress, submitFailure) where

import Control.Monad (void)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime, addUTCTime)
import Database.PostgreSQL.Simple.Types (Only (..))
import Effectful
import Effectful.PostgreSQL (WithConnection, execute, query)
import Max.DB.Task.Authorization
import Max.DB.Task.Record
import Max.DB.Transaction (InTransaction, withTransaction)
import Max.Skill.Contract (parseContract)
import Max.Task.Delegation (validateAgentPayload)
import Max.Task.Execution (ExecutionFailure (..))
import Max.Task.State
import Max.Task.Types (taskHandle)
import Max.Turn.Types (AgentTurnId)

submitReport :: (WithConnection :> es, IOE :> es) => AgentTurnId -> TaskReport -> Eff es Bool
submitReport turn report = either (const False) (const True) <$> submitReportChecked turn report

submitReportChecked :: (WithConnection :> es, IOE :> es) => AgentTurnId -> TaskReport -> Eff es (Either ExecutionFailure ())
submitReportChecked turn report = withAuthorizedOr (Left ExecutionReportRejected) turn $ \task -> do
  structured <- case task.monitorFire of
    Nothing -> pure False
    Just fire -> do
      rows <- query "SELECT COALESCE((definition_snapshot->>'change_only')::boolean,false) FROM monitor_fires WHERE fire_id=?" (Only fire)
      pure (rows == [Only True])
  let validObservation = case report.observation of
        Just (Object fields) -> not (KeyMap.null fields)
        _ -> False
      observationRequired = structured && report.status `elem` [ReportSucceeded, ReportPartial]
      contract = case task.inputs of
        Object fields -> case KeyMap.lookup "output_contract" fields of
          Just Null -> Nothing
          value -> value
        _ -> Nothing
  children <-
    query
      "SELECT EXISTS(SELECT 1 FROM durable_tasks child JOIN task_attempts parent ON child.parent_task_id=parent.task_id\
      \ AND child.parent_revision=parent.revision WHERE parent.turn_id=? AND child.status IN ('queued','running','waiting','retrying'))"
      (Only turn)
  case traverse parseContract contract >>= (\parsed -> validateAgentPayload parsed report) of
    Left detail -> pure (Left (ExecutionInvalidPayload detail))
    Right () ->
      if (observationRequired && not validObservation) || (report.status == ReportSucceeded && children == [Only True])
        then pure (Left ExecutionReportRejected)
        else do
          moved <-
            execute
              "UPDATE task_attempts SET report=?::jsonb WHERE turn_id=? AND (report IS NULL OR report=?::jsonb)"
              (jsonText report, turn, jsonText report)
          pure (if moved == 1 then Right () else Left ExecutionReportRejected)

submitFailure :: (WithConnection :> es, IOE :> es) => AgentTurnId -> Text -> FailureKind -> Eff es Bool
submitFailure turn detail kind = withAuthorized turn $ \_ -> do
  let report = TaskReport ReportFailed (T.take 40000 detail) [] [] (Just kind) Nothing Nothing
  moved <-
    execute
      "UPDATE task_attempts SET retryable=?,report=?::jsonb WHERE turn_id=? AND report IS NULL"
      (kind == Transient, jsonText report, turn)
  pure (moved == 1)

submitProgress :: (WithConnection :> es, IOE :> es) => AgentTurnId -> Text -> Eff es Bool
submitProgress turn summary
  | T.null (T.strip summary) || T.length summary > 40000 = pure False
  | otherwise = withAuthorized turn $ \task -> do
      let progress = object ["status" .= ("running" :: Text), "summary" .= summary]
      previous <- query "SELECT revision,attempt,body FROM task_progress WHERE task_id=?" (Only task.taskId)
      if previous == [(task.revision, task.attempt, progress)]
        then pure True
        else do
          versions <-
            query
              "INSERT INTO task_progress(task_id,revision,attempt,body) VALUES(?,?,?,?::jsonb)\
              \ ON CONFLICT(task_id) DO UPDATE SET revision=excluded.revision,attempt=excluded.attempt,\
              \ version=task_progress.version+1,body=excluded.body,updated_at=now() RETURNING version"
              (task.taskId, task.revision, task.attempt, jsonText progress)
          version <- case versions :: [Only Int64] of
            [Only value] -> pure value
            _ -> error "progress upsert did not return its version"
          case task.parent of
            Just parent ->
              void $
                execute
                  "INSERT INTO task_events(task_id,revision,kind,body) SELECT task_id,revision,'child_progress',?\
                  \ FROM durable_tasks WHERE task_id=? AND revision=? AND status IN ('queued','running','waiting','retrying')"
                  (T.take 60000 (taskHandle task.taskId <> ": " <> jsonText progress), parent, task.parentRevision)
            Nothing -> routeProgress task version progress
          pure True

routeProgress :: (WithConnection :> es, IOE :> es) => TaskRecord -> Int64 -> Value -> Eff es ()
routeProgress task version progress = do
  -- A newer progress version fences publication of the older snapshot.
  void $
    execute
      "UPDATE task_notifications SET superseded_at=clock_timestamp() WHERE task_id=? AND kind='progress'\
      \ AND turn_id IS NOT NULL AND delivered_at IS NULL AND superseded_at IS NULL"
      (Only task.taskId)
  pending <-
    query
      "SELECT notification_id FROM task_notifications WHERE task_id=? AND kind='progress' AND turn_id IS NULL\
      \ AND delivered_at IS NULL AND superseded_at IS NULL\
      \ ORDER BY notification_id DESC LIMIT 1 FOR UPDATE"
      (Only task.taskId)
  case pending :: [Only Int64] of
    [Only notification] ->
      void $
        execute
          "UPDATE task_notifications SET body=?::jsonb,revision=?,attempt=?,progress_version=? WHERE notification_id=?"
          (jsonText progress, task.revision, task.attempt, version, notification)
    _ -> do
      previous <- query "SELECT max(created_at) FROM task_notifications WHERE task_id=? AND kind='progress'" (Only task.taskId)
      now <- databaseNow
      let wake = case previous :: [Only (Maybe UTCTime)] of
            [Only (Just created)] -> max now (addUTCTime 30 created)
            _ -> now
      void $
        execute
          "INSERT INTO task_notifications(task_id,revision,attempt,body,kind,next_attempt_at,progress_version) VALUES(?,?,?,?::jsonb,'progress',?,?)"
          (task.taskId, task.revision, task.attempt, jsonText progress, wake, version)

withAuthorized :: (WithConnection :> es, IOE :> es) => AgentTurnId -> (TaskRecord -> Eff (InTransaction : es) Bool) -> Eff es Bool
withAuthorized = withAuthorizedOr False

withAuthorizedOr :: (WithConnection :> es, IOE :> es) => a -> AgentTurnId -> (TaskRecord -> Eff (InTransaction : es) a) -> Eff es a
withAuthorizedOr fallback turn action = withTransaction $ do
  _ <- lockTurnConversation turn
  allowed <- authorizeWithin turn ExecutionCheckpoint
  if not allowed
    then pure fallback
    else do
      attempt <- loadAttempt turn
      case attempt of
        Nothing -> pure fallback
        Just execution -> do
          task <- loadTask execution.taskId
          maybe (pure fallback) action task
