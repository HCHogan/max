-- | Current-attempt reporting. Validation, progress coalescing and notification
-- spacing are host policies; every read and write shares one transaction.
module Max.DB.Task.Reporting (submitReport, submitProgress, submitFailure, submitRequest) where

import Control.Monad (void)
import Data.Aeson (Value, object, (.=))
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime, addUTCTime)
import Database.PostgreSQL.Simple.Types (Only (..))
import Effectful
import Effectful.PostgreSQL (WithConnection, execute, query)
import Max.DB.Task.Authorization
import Max.DB.Task.Record
import Max.DB.Transaction (withTransaction)
import Max.Task.State
import Max.Task.Types (taskHandle)
import Max.Turn.Types (AgentTurnId)

submitReport :: (WithConnection :> es, IOE :> es) => AgentTurnId -> TaskReport -> Eff es Bool
submitReport turn report = withAuthorized turn $ \_ -> do
  children <-
    query
      "SELECT EXISTS(SELECT 1 FROM durable_tasks child JOIN task_attempts parent ON child.parent_task_id=parent.task_id\
      \ AND child.parent_revision=parent.revision WHERE parent.turn_id=? AND child.status IN ('queued','running','waiting','retrying'))"
      (Only turn)
  if report.status == ReportSucceeded && children == [Only True]
    then pure False
    else do
      moved <-
        execute
          "UPDATE task_attempts SET report=?::jsonb WHERE turn_id=? AND (report IS NULL OR report=?::jsonb)"
          (jsonText report, turn, jsonText report)
      pure (moved == 1)

submitFailure :: (WithConnection :> es, IOE :> es) => AgentTurnId -> Text -> FailureKind -> Eff es Bool
submitFailure turn detail kind = withAuthorized turn $ \_ -> do
  let report = TaskReport ReportFailed (T.take 40000 detail) [] [] (Just kind) Nothing
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
  -- Claimed snapshots are immutable. A newer version revokes an in-flight
  -- review; its lease watcher cancels the model and the output guard rejects
  -- any response that raced the update.
  void $ execute
    "UPDATE task_notifications SET superseded_at=clock_timestamp() WHERE task_id=? AND kind='progress'\
    \ AND turn_id IS NOT NULL AND delivered_at IS NULL AND superseded_at IS NULL\
    \ AND review_decision->>'action' IS DISTINCT FROM 'skip'"
    (Only task.taskId)
  pending <-
    query
      "SELECT notification_id FROM task_notifications WHERE task_id=? AND kind='progress' AND turn_id IS NULL\
      \ AND delivered_at IS NULL AND superseded_at IS NULL AND review_decision->>'action' IS DISTINCT FROM 'skip'\
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

submitRequest :: (WithConnection :> es, IOE :> es) => AgentTurnId -> RequestDisposition -> Text -> Eff es Bool
submitRequest turn disposition reply
  | disposition `notElem` [RequestAnswered, RequestWaiting, RequestDeclined] || T.null trimmed || T.length trimmed > 40000 = pure False
  | otherwise = withTransaction $ do
      _ <- lockTurnConversation turn
      authorized <- authorizeWithin turn ExecutionCheckpoint
      frontend <-
        query
          "SELECT EXISTS(SELECT 1 FROM conversation_frontends WHERE turn_id=? AND lease_until>clock_timestamp()),\
          \ EXISTS(SELECT 1 FROM task_notifications WHERE turn_id=?)"
          (turn, turn)
      if not authorized || frontend /= [(True, False)]
        then pure False
        else do
          void $
            execute
              "INSERT INTO request_outcomes(turn_id,disposition,reply) VALUES(?,?,?) ON CONFLICT(turn_id) DO NOTHING"
              (turn, dispositionText disposition, trimmed)
          recorded <- query "SELECT disposition,reply FROM request_outcomes WHERE turn_id=?" (Only turn)
          pure (recorded == [(dispositionText disposition, trimmed)])
  where
    trimmed = T.strip reply

withAuthorized :: (WithConnection :> es, IOE :> es) => AgentTurnId -> (TaskRecord -> Eff es Bool) -> Eff es Bool
withAuthorized turn action = withTransaction $ do
  _ <- lockTurnConversation turn
  allowed <- authorizeWithin turn ExecutionCheckpoint
  if not allowed
    then pure False
    else do
      attempt <- loadAttempt turn
      case attempt of
        Nothing -> pure False
        Just execution -> do
          task <- loadTask execution.taskId
          maybe (pure False) action task
