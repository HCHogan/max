-- | Versioned review snapshots and decisions. No model or outbound effects.
module Max.DB.Task.Progress (loadProgressReview, progressReviewCurrent, progressReviewHandled, recordProgressDecision) where

import Data.Aeson (Value, fromJSON, Result (..))
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
import Max.Task.Progress
import Max.Turn.Types (AgentTurnId)

loadProgressReview :: (WithConnection :> es, IOE :> es) => AgentTurnId -> Eff es (Maybe ProgressReview)
loadProgressReview turn = withTransaction $ do
  authorized <- authorizeWithin turn ExecutionCheckpoint
  rows <- if authorized then query
    "SELECT t.conversation_id,t.task_id,n.revision,n.attempt,n.progress_version,left(t.objective,4000),n.body->>'summary',\
    \ (SELECT COALESCE(previous.review_decision->>'reply',previous.body->>'summary') FROM task_notifications previous\
    \ WHERE previous.task_id=t.task_id AND previous.kind='progress' AND previous.delivered_at IS NOT NULL\
    \ ORDER BY previous.delivered_at DESC,previous.notification_id DESC LIMIT 1),n.review_decision\
    \ FROM task_notifications n JOIN durable_tasks t USING(task_id) JOIN task_progress p USING(task_id)\
    \ WHERE n.turn_id=? AND n.kind='progress' AND n.progress_version=p.version\
    \ AND n.delivered_at IS NULL AND n.superseded_at IS NULL\
    \ AND n.review_decision->>'action' IS DISTINCT FROM 'skip'\
    \ AND NOT EXISTS(SELECT 1 FROM messages m WHERE m.agent_turn_id=n.turn_id)"
    (Only turn) else pure []
  case rows :: [(Int64, Int64, Int, Int, Int64, Text, Text, Maybe Text, Maybe Value)] of
    [(conversation, task, revision, attempt, version, objective, summary, previous, stored)] -> do
      waiting <- frontendWorkWaitingWithin conversation (Just turn)
      let decoded = traverse (\value -> case fromJSON value of Success decision -> Just decision; Error _ -> Nothing) stored
      pure $ if waiting then Nothing else ProgressReview task revision attempt version objective summary previous <$> decoded
    _ -> pure Nothing

progressReviewCurrent :: (WithConnection :> es, IOE :> es) => AgentTurnId -> Eff es Bool
progressReviewCurrent turn = isJust <$> loadProgressReview turn

-- A crash between a committed decision/publication and the terminal turn
-- checkpoint must not turn an already-handled notice into another model call.
progressReviewHandled :: (WithConnection :> es, IOE :> es) => AgentTurnId -> Eff es Bool
progressReviewHandled turn = do
  rows <- query
    "SELECT EXISTS(SELECT 1 FROM task_notifications n WHERE n.turn_id=? AND n.kind='progress'\
    \ AND (n.review_decision->>'action'='skip' OR EXISTS(SELECT 1 FROM messages m WHERE m.agent_turn_id=n.turn_id)))"
    (Only turn)
  pure (rows == [Only True])

recordProgressDecision :: (WithConnection :> es, IOE :> es) => AgentTurnId -> Int64 -> ProgressDecision -> Eff es Bool
recordProgressDecision turn version decision = case validateProgressDecision decision of
  Left _ -> pure False
  Right valid -> withTransaction $ do
    current <- loadProgressReview turn
    case current of
      Just review | review.version == version -> case review.decision of
        Just previous -> pure (previous == valid)
        Nothing -> do
          changed <- execute
            "UPDATE task_notifications SET review_decision=?::jsonb,reviewed_at=clock_timestamp(),last_error=NULL\
            \ WHERE turn_id=? AND progress_version=? AND review_decision IS NULL"
            (jsonText valid, turn, version)
          pure (changed == 1)
      _ -> pure False
