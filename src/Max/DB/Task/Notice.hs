-- | Versioned review snapshots and decisions. No model or outbound effects.
module Max.DB.Task.Notice (loadNoticeReview, noticeReviewCurrent, noticeReviewHandled, recordNoticeDecision) where

import Data.Aeson (Result (..), Value, fromJSON)
import Data.Int (Int64)
import Data.Maybe (isJust)
import Data.Text (Text)
import Database.PostgreSQL.Simple.Types (Only (..))
import Effectful
import Effectful.PostgreSQL (WithConnection, execute, query)
import Max.DB.Task.Authorization (authorizeWithin)
import Max.DB.Task.Frontend (frontendWorkWaitingWithin)
import Max.DB.Task.Record (jsonText)
import Max.DB.Transaction (withTransaction)
import Max.Execution.Types (ExecutionStep (ExecutionCheckpoint))
import Max.Task.Notice
import Max.Turn.Types (AgentTurnId)

loadNoticeReview :: (WithConnection :> es, IOE :> es) => AgentTurnId -> Eff es (Maybe NoticeReview)
loadNoticeReview turn = withTransaction $ do
  authorized <- authorizeWithin turn ExecutionCheckpoint
  rows <-
    if authorized
      then
        query
          "SELECT t.conversation_id,t.task_id,n.revision,n.attempt,COALESCE(n.progress_version,n.notification_id),n.kind,left(t.objective,4000),CASE WHEN n.kind='progress' THEN n.body->>'summary' ELSE n.body::text END,\
          \ (SELECT COALESCE(previous.review_decision->>'reply',previous.body->>'summary') FROM task_notifications previous\
          \ WHERE previous.task_id=t.task_id AND previous.kind=n.kind AND previous.delivered_at IS NOT NULL\
          \ ORDER BY previous.delivered_at DESC,previous.notification_id DESC LIMIT 1),n.review_decision\
          \ FROM task_notifications n JOIN durable_tasks t USING(task_id) LEFT JOIN task_progress p USING(task_id)\
          \ WHERE n.turn_id=? AND (n.kind='result' OR n.progress_version=p.version)\
          \ AND n.delivered_at IS NULL AND n.superseded_at IS NULL\
          \ AND n.review_decision->>'action' IS DISTINCT FROM 'skip'\
          \ AND NOT EXISTS(SELECT 1 FROM messages m WHERE m.agent_turn_id=n.turn_id)"
          (Only turn)
      else pure []
  case rows :: [(Int64, Int64, Int, Int, Int64, Text, Text, Text, Maybe Text, Maybe Value)] of
    [(conversation, task, revision, attempt, version, kind, objective, summary, previous, stored)] -> do
      waiting <- frontendWorkWaitingWithin conversation (Just turn)
      obligations <-
        query
          "SELECT EXISTS(SELECT 1 FROM durable_tasks t JOIN conversation_requests r ON r.message_id=t.source_message_id\
          \ OR EXISTS(SELECT 1 FROM task_events e WHERE e.task_id=t.task_id AND e.source_message_id=r.message_id)\
          \ WHERE t.task_id=? AND t.monitor_fire_id IS NULL AND r.disposition IN ('pending','delegated','waiting'))"
          (Only task)
      let required = kind == "result" && obligations == [Only True]
          decoded = traverse (\value -> case fromJSON value of Success decision -> Just decision; Error _ -> Nothing) stored
      pure $ if waiting then Nothing else NoticeReview task revision attempt version kind objective summary previous required <$> decoded
    _ -> pure Nothing

noticeReviewCurrent :: (WithConnection :> es, IOE :> es) => AgentTurnId -> Eff es Bool
noticeReviewCurrent turn = isJust <$> loadNoticeReview turn

-- A crash between a committed decision/publication and the terminal turn
-- checkpoint must not turn an already-handled notice into another model call.
noticeReviewHandled :: (WithConnection :> es, IOE :> es) => AgentTurnId -> Eff es Bool
noticeReviewHandled turn = do
  rows <-
    query
      "SELECT EXISTS(SELECT 1 FROM task_notifications n WHERE n.turn_id=?\
      \ AND (n.review_decision->>'action'='skip' OR EXISTS(SELECT 1 FROM messages m WHERE m.agent_turn_id=n.turn_id)))"
      (Only turn)
  pure (rows == [Only True])

recordNoticeDecision :: (WithConnection :> es, IOE :> es) => AgentTurnId -> Int64 -> NoticeDecision -> Eff es Bool
recordNoticeDecision turn version decision = case validateNoticeDecision decision of
  Left _ -> pure False
  Right valid -> withTransaction $ do
    current <- loadNoticeReview turn
    case current of
      Just review | review.replyRequired, SkipNotice _ <- valid -> pure False
      Just review | review.version == version -> case review.decision of
        Just previous -> pure (previous == valid)
        Nothing -> do
          changed <-
            execute
              "UPDATE task_notifications SET review_decision=?::jsonb,reviewed_at=clock_timestamp(),last_error=NULL\
              \ WHERE turn_id=? AND COALESCE(progress_version,notification_id)=? AND review_decision IS NULL"
              (jsonText valid, turn, version)
          pure (changed == 1)
      _ -> pure False
