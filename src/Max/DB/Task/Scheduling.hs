-- | Bounded scheduling under one reservation lock. SQL selects eligible
-- rows; Haskell owns limits, deadlines, retries and explicit settlement.
module Max.DB.Task.Scheduling (claimTask) where

import Control.Monad (forM_, void, when)
import Data.Int (Int64)
import Data.Text (Text)
import Data.Time (addUTCTime)
import Database.PostgreSQL.Simple.Types (Only (..))
import Effectful
import Effectful.PostgreSQL (WithConnection, execute, query)
import Max.DB.Task.Record
import Max.DB.Task.Settlement
import Max.DB.Transaction (withTransaction)
import Max.Task.State
import Max.Turn.Types (AgentTurnId)

claimTask :: (WithConnection :> es, IOE :> es) => Text -> Eff es [AgentTurnId]
claimTask owner = withTransaction $ do
  -- Shared with all claimers, so capacity checks and reservation commit once.
  locked <- query "SELECT 1::integer FROM (SELECT pg_advisory_xact_lock(872008)) reservation" ()
  case locked :: [Only Int] of
    [_] -> pure ()
    _ -> error "task scheduling lock missing"
  candidates <- eligibleTask Nothing
  case candidates of
    [Only identifier] -> do
      _ <- lockTaskConversation identifier
      -- Control/settlement could have changed the candidate while this worker
      -- was waiting for its conversation. Re-evaluate eligibility under lock.
      stillEligible <- eligibleTask (Just identifier)
      task <- if stillEligible == candidates then loadTask identifier else pure Nothing
      maybe (pure []) start task
    _ -> pure []
  where
    start task = do
      now <- databaseNow
      if task.deadline <= now || task.attempt >= 40
        then do
          completeTask task BudgetExhausted (Just (TaskReport ReportBudgetExhausted "deadline or retry budget exhausted" [] [] Nothing Nothing))
          pure []
        else do
          when (task.status == Running) $ do
            -- Fence old attempts before settling their turns. Their reports
            -- cannot overwrite the next attempt or replay unknown effects.
            void $ execute "UPDATE durable_tasks SET status='queued' WHERE task_id=?" (Only task.taskId)
            void $
              execute
                "UPDATE execution_journal SET state='outcome-unknown',finished_at=now(),failure_code='task_lease_expired'\
                \ WHERE state='started' AND turn_id IN (SELECT turn_id FROM task_attempts WHERE task_id=?)"
                (Only task.taskId)
            expired <-
              query
                "UPDATE agent_turns SET status='crashed',finished_at=now(),abort_reason='task execution lease expired'\
                \ WHERE status IN ('starting','running','recovery-pending') AND turn_id IN (SELECT turn_id FROM task_attempts WHERE task_id=?) RETURNING turn_id,frontend_managed"
                (Only task.taskId)
            forM_ expired $ \(turn, managed) -> settleTurn turn False (Just "task execution lease expired") managed
          turns <-
            query
              "INSERT INTO agent_turns(conversation_id,turn_ordinal,trigger_canonical_message_id,initiator_principal_id,status)\
              \ SELECT ?,COALESCE(max(turn_ordinal),0)+1,?,?,'starting' FROM agent_turns WHERE conversation_id=? RETURNING turn_id"
              (task.conversationId, task.sourceMessage, task.owner, task.conversationId)
          case turns of
            [Only turn] -> do
              void $ execute "UPDATE durable_tasks SET status='running',attempt=attempt+1,next_attempt_at=NULL,updated_at=now() WHERE task_id=?" (Only task.taskId)
              void $
                execute
                  "INSERT INTO task_attempts(turn_id,task_id,revision,attempt,owner,lease_until) VALUES(?,?,?,?,?,?)"
                  (turn, task.taskId, task.revision, task.attempt + 1, owner, addUTCTime 60 now)
              pure [turn]
            _ -> error "task claim did not create a turn"

eligibleTask :: (WithConnection :> es, IOE :> es) => Maybe Int64 -> Eff es [Only Int64]
eligibleTask identifier =
  query
    "SELECT work.task_id FROM durable_tasks work WHERE (work.status='queued'\
    \ OR work.status='retrying' AND work.next_attempt_at<=clock_timestamp()\
    \ OR work.status='running' AND NOT EXISTS (SELECT 1 FROM task_attempts execution WHERE execution.task_id=work.task_id\
    \ AND execution.attempt=work.attempt AND execution.lease_until>clock_timestamp())\
    \ OR work.status IN ('waiting','retrying') AND work.deadline<=clock_timestamp())\
    \ AND (SELECT count(*) FROM durable_tasks active JOIN task_attempts execution ON execution.task_id=active.task_id AND execution.attempt=active.attempt\
    \ WHERE active.status='running' AND execution.lease_until>clock_timestamp())<?\
    \ AND (SELECT count(*) FROM durable_tasks active JOIN task_attempts execution ON execution.task_id=active.task_id AND execution.attempt=active.attempt\
    \ WHERE active.status='running' AND execution.lease_until>clock_timestamp() AND active.conversation_id=work.conversation_id)<?\
    \ AND (SELECT count(*) FROM durable_tasks active JOIN task_attempts execution ON execution.task_id=active.task_id AND execution.attempt=active.attempt\
    \ WHERE active.status='running' AND execution.lease_until>clock_timestamp() AND active.owner_principal_id=work.owner_principal_id)<?\
    \ AND (work.monitor_fire_id IS NULL OR NOT EXISTS (\
    \ SELECT 1 FROM durable_tasks active JOIN monitor_fires active_fire ON active_fire.fire_id=active.monitor_fire_id\
    \ JOIN monitor_fires candidate_fire ON candidate_fire.fire_id=work.monitor_fire_id\
    \ WHERE active.task_id<>work.task_id AND active.status='running' AND active_fire.monitor_id=candidate_fire.monitor_id\
    \ AND EXISTS(SELECT 1 FROM task_attempts execution WHERE execution.task_id=active.task_id AND execution.attempt=active.attempt AND execution.lease_until>clock_timestamp())))\
    \ AND (work.parent_task_id IS NULL OR EXISTS (SELECT 1 FROM durable_tasks parent WHERE parent.task_id=work.parent_task_id AND parent.status IN ('queued','running','waiting','retrying')))\
    \ AND (?::bigint IS NULL OR work.task_id=?)\
    \ ORDER BY (SELECT max(previous.updated_at) FROM durable_tasks previous WHERE previous.owner_principal_id=work.owner_principal_id AND previous.attempt>0) NULLS FIRST,\
    \ work.updated_at,work.task_id LIMIT 1"
    (40 :: Int, 10 :: Int, 10 :: Int, identifier, identifier)
