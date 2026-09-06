-- | Execution authority is checked under the conversation commit lock. This
-- module never calls an effectful tool; it reserves budgets before that edge.
module Max.DB.Task.Authorization
  ( StepReservation (..),
    ExecutionStep (..),
    authorizeWithin,
    authorizeCallerWithin,
    reserveResourceWithin,
  )
where

import Control.Monad (void)
import Data.Int (Int64)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Database.PostgreSQL.Simple.Types (Only (..))
import Effectful
import Effectful.PostgreSQL (WithConnection, execute, query)
import Max.DB.Task.Record
import Max.Execution.Types (ExecutionStep (..), StepReservation (..))
import Max.Platform.Types (PrincipalId (..))
import Max.Task.State
import Max.Turn.Types (AgentTurnId)
import OneBot.Types (GroupId (..))

-- | The caller owns a pinned transaction. Re-read turn state after acquiring
-- its conversation lock; a pre-lock snapshot is never sufficient authority.
authorizeWithin :: (WithConnection :> es, IOE :> es) => AgentTurnId -> ExecutionStep -> Eff es Bool
authorizeWithin turn step = do
  locked <- lockTurnConversation turn
  active <-
    if locked
      then
        query
          "SELECT frontend_managed FROM agent_turns WHERE turn_id=? AND status IN ('starting','running','recovery-pending') FOR UPDATE"
          (Only turn)
      else pure []
  case active of
    [Only managed] -> do
      frontend <- query "SELECT EXISTS(SELECT 1 FROM conversation_frontends WHERE turn_id=? AND lease_until>clock_timestamp())" (Only turn)
      stale <-
        query
          "SELECT EXISTS(SELECT 1 FROM task_notifications notice JOIN durable_tasks work USING(task_id) LEFT JOIN task_progress progress USING(task_id)\
          \ WHERE notice.turn_id=? AND (notice.revision<>work.revision OR notice.attempt<>work.attempt\
          \ OR notice.body->>'status' IS DISTINCT FROM work.status OR work.status='cancelled' OR notice.superseded_at IS NOT NULL\
          \ OR (notice.kind='progress' AND (notice.progress_version IS DISTINCT FROM progress.version OR notice.review_decision->>'action'='skip'))))"
          (Only turn)
      if (managed && frontend /= [Only True]) || stale == [Only True]
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

-- | Sandbox affinity is a scoped reservation, retained for unknown effects
-- after terminal work. The resource row never grants execution authority.
reserveResourceWithin :: (WithConnection :> es, IOE :> es) => AgentTurnId -> Text -> Eff es Bool
reserveResourceWithin turn resource = do
  authorized <- authorizeWithin turn ExecutionCheckpoint
  present <-
    query
      "SELECT EXISTS(SELECT 1 FROM sandboxes sandbox JOIN agent_turns turn USING(conversation_id)\
      \ WHERE turn.turn_id=? AND sandbox.sandbox_handle=? AND sandbox.status<>'destroyed')"
      (turn, resource)
  if not authorized || present /= [Only True]
    then pure False
    else do
      attempt <- loadAttempt turn
      (_ :: [Only Int]) <-
        query
          "SELECT 1::integer FROM (SELECT pg_advisory_xact_lock(hashtextextended('task-resource:'||?::text,0))) reservation"
          (Only resource)
      void $
        execute
          "DELETE FROM task_resource_owners owner USING durable_tasks work WHERE owner.task_id=work.task_id\
          \ AND owner.resource=? AND work.status NOT IN ('running','queued','waiting','retrying')\
          \ AND NOT EXISTS(SELECT 1 FROM task_attempts execution JOIN execution_journal journal USING(turn_id)\
          \ WHERE execution.task_id=owner.task_id AND journal.state IN ('started','outcome-unknown') AND journal.normalized_input->>'sandbox_id'=?)"
          (resource, resource)
      owners <- query "SELECT task_id FROM task_resource_owners WHERE resource=?" (Only resource)
      let identifier = (.taskId) <$> attempt
      case owners :: [Only Int64] of
        [Only current] -> pure (Just current == identifier)
        [] -> do
          case identifier of
            Just task -> void $ execute "INSERT INTO task_resource_owners(resource,task_id) VALUES(?,?)" (resource, task)
            Nothing -> pure ()
          pure True
        _ -> error "resource uniqueness violated"

-- | Reuse the locked execution check without accepting a caller-selected actor
-- or conversation. Callers keep this inside the mutation's pinned transaction.
authorizeCallerWithin :: (WithConnection :> es, IOE :> es) => AgentTurnId -> GroupId -> PrincipalId -> Eff es Bool
authorizeCallerWithin turn (GroupId group) (PrincipalId actor) = do
  authorized <- authorizeWithin turn (ExecutionWork CheckOnly)
  identity <- query "SELECT EXISTS(SELECT 1 FROM agent_turns JOIN conversations USING(conversation_id) WHERE turn_id=? AND initiator_principal_id=? AND legacy_group_id=?)" (turn, actor, group)
  pure (authorized && identity == [Only True])
