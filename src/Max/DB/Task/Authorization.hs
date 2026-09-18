-- | Execution authority is checked under the conversation commit lock. This
-- module never calls an effectful tool; it reserves budgets before that edge.
module Max.DB.Task.Authorization
  ( StepReservation (..),
    ExecutionStep (..),
    authorizeWithin,
    authorizeCallerWithin,
  )
where

import Control.Monad (void)
import Data.Maybe (fromMaybe)
import Database.PostgreSQL.Simple.Types (Only (..))
import Effectful
import Effectful.PostgreSQL (WithConnection, execute, query)
import Max.DB.Task.Record
import Max.DB.Transaction (InTransaction, requireTransaction)
import Max.Execution.Types
  ( ExecutionStep (..),
    StepReservation (..),
  )
import Max.Platform.Types (PrincipalId (..))
import Max.Task.State
import Max.Turn.Types (AgentTurnId)
import OneBot.Types (GroupId (..))

-- | The caller owns a pinned transaction. Re-read turn state after acquiring
-- its conversation lock; a pre-lock snapshot is never sufficient authority.
authorizeWithin :: (InTransaction :> es, WithConnection :> es, IOE :> es) => AgentTurnId -> ExecutionStep -> Eff es Bool
authorizeWithin turn step = do
  requireTransaction
  locked <- lockTurnConversation turn
  active <-
    if locked
      then
        query
          "SELECT true FROM agent_turns WHERE turn_id=? AND status IN ('starting','running','recovery-pending') FOR UPDATE"
          (Only turn)
      else pure []
  case active of
    [Only True] -> do
      stale <-
        query
          "SELECT EXISTS(SELECT 1 FROM task_notifications notice JOIN durable_tasks work USING(task_id) LEFT JOIN task_progress progress USING(task_id)\
          \ WHERE notice.turn_id=? AND (notice.revision<>work.revision OR notice.attempt<>work.attempt\
          \ OR notice.body->>'status' IS DISTINCT FROM work.status OR work.status='cancelled' OR notice.superseded_at IS NOT NULL\
          \ OR (notice.kind='progress' AND notice.progress_version IS DISTINCT FROM progress.version)))"
          (Only turn)
      if stale == [Only True]
        then pure False
        else do
          attempt <- loadAttempt turn
          case attempt of
            Nothing -> pure True
            Just execution -> do
              work <- loadTask execution.taskId
              case work of
                Nothing -> pure False
                Just task -> do
                  root <- loadTask (fromMaybe task.taskId task.root)
                  ancestors <-
                    query
                      "WITH RECURSIVE ancestors AS (SELECT parent_task_id,parent_revision FROM durable_tasks WHERE task_id=?\
                      \ UNION ALL SELECT work.parent_task_id,work.parent_revision FROM durable_tasks work JOIN ancestors ON work.task_id=ancestors.parent_task_id)\
                      \ SELECT EXISTS(SELECT 1 FROM ancestors JOIN durable_tasks work ON work.task_id=ancestors.parent_task_id\
                      \ WHERE work.status NOT IN ('running','queued','waiting','retrying') OR work.revision<>ancestors.parent_revision)"
                      (Only task.taskId)
                  now <- databaseNow
                  case root of
                    Just budget
                      | task.status == Running
                          && task.revision == execution.revision
                          && task.attempt == execution.attempt
                          && execution.leaseUntil > now
                          && taskIsLive budget.status
                          && ancestors == [Only False] ->
                          case step of
                            ExecutionCheckpoint -> pure True
                            ExecutionWork reservation
                              | task.deadline <= now || budget.deadline <= now -> pure False
                              | not (available reservation task && available reservation budget) -> pure False
                              | otherwise -> do
                                  case reservation of
                                    CheckOnly -> pure ()
                                    ReserveCall -> void $ execute "UPDATE durable_tasks SET calls_reserved=calls_reserved+1 WHERE task_id IN (?,?)" (task.taskId, budget.taskId)
                                    ReserveRound -> void $ execute "UPDATE durable_tasks SET rounds_reserved=rounds_reserved+1 WHERE task_id IN (?,?)" (task.taskId, budget.taskId)
                                  pure True
                    _ -> pure False
    _ -> pure False
  where
    available CheckOnly _ = True
    available ReserveCall task = task.calls < task.maxCalls
    available ReserveRound task = task.rounds < task.maxRounds

-- | Reuse the locked execution check without accepting a caller-selected actor
-- or conversation. Callers keep this inside the mutation's pinned transaction.
authorizeCallerWithin :: (InTransaction :> es, WithConnection :> es, IOE :> es) => AgentTurnId -> GroupId -> PrincipalId -> Eff es Bool
authorizeCallerWithin turn (GroupId group) (PrincipalId actor) = do
  authorized <- authorizeWithin turn (ExecutionWork CheckOnly)
  identity <- query "SELECT EXISTS(SELECT 1 FROM agent_turns JOIN conversations USING(conversation_id) WHERE turn_id=? AND initiator_principal_id=? AND legacy_group_id=?)" (turn, actor, group)
  pure (authorized && identity == [Only True])
