-- | Durable workflow joins over existing tasks. Admission, fencing and budgets
-- remain owned by the task subsystem; no model or guest runs in a transaction.
module Max.DB.Task.Workflow
  ( AgentStep (..),
    beginAgentStep,
    pollAgentStep,
    endAgentWait,
    workflowAllowed,
    workflowSteeringPending,
  )
where

import Control.Monad (void, when)
import Data.Aeson (Value, object, (.=))
import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (isNothing)
import Data.Text (Text)
import Database.PostgreSQL.Simple.Types (Only (..))
import Effectful
import Effectful.PostgreSQL (WithConnection, execute, query)
import Max.DB.Task.Admission (admitTaskWithin)
import Max.DB.Task.Authorization
import Max.DB.Task.Record
import Max.DB.Transaction (withTransaction)
import Max.Task.Admission (admissionErrorText)
import Max.Task.Delegation
import Max.Task.State
import Max.Task.Types
import Max.Turn.Types (AgentTurnId)

data AgentStep = AgentStep
  { childId :: !Int64,
    childRevision :: !Int,
    originalJournal :: !Int64,
    cached :: !(Maybe Value)
  }
  deriving stock (Eq, Show)

-- Frontends may still run ordinary workflows. An awaited child may only run
-- the normal agent loop, including after a crash/restart or an ordinary task
-- delegation beneath it. A grandchild cannot reopen a guest as an escape hatch.
workflowAllowed :: (WithConnection :> es, IOE :> es) => AgentTurnId -> Eff es Bool
workflowAllowed turn = do
  rows <-
    query
      "WITH RECURSIVE ancestors AS (SELECT task_id FROM task_attempts WHERE turn_id=? \
      \ UNION ALL SELECT work.parent_task_id FROM durable_tasks work JOIN ancestors ON work.task_id=ancestors.task_id WHERE work.parent_task_id IS NOT NULL) \
      \ SELECT NOT EXISTS(SELECT 1 FROM ancestors JOIN workflow_agent_steps step ON step.child_task_id=ancestors.task_id)"
      (Only turn)
  pure (rows == [Only True])

workflowSteeringPending :: (WithConnection :> es, IOE :> es) => AgentTurnId -> Eff es Bool
workflowSteeringPending turn = do
  rows <-
    query
      "SELECT EXISTS(SELECT 1 FROM task_events event JOIN durable_tasks work USING(task_id) JOIN task_attempts attempt USING(task_id) \
      \ WHERE attempt.turn_id=? AND attempt.revision=work.revision AND attempt.attempt=work.attempt \
      \ AND event.kind='steer' AND event.event_id>GREATEST(work.consumed_event,attempt.seen_event))"
      (Only turn)
  pure (rows == [Only True])

beginAgentStep :: (WithConnection :> es, IOE :> es) => AgentTurnId -> Map Text Text -> Value -> AgentRequest -> Int64 -> Eff es (Either Text AgentStep)
beginAgentStep turn currentGrants receipts request journal = withTransaction $ do
  allowed <- authorizeWithin turn (ExecutionWork CheckOnly)
  pending <- workflowSteeringPending turn
  attempt <- loadAttempt turn
  parent <- maybe (pure Nothing) (loadTask . (.taskId)) attempt
  case parent of
    Just task | allowed && not pending && isNothing task.parent && Map.member "task_start" currentGrants && Map.lookup "task_start" currentGrants == Map.lookup "task_start" task.grants -> do
      let same name contract = Map.lookup name task.grants == Just contract
          authority = Map.filterWithKey same currentGrants
          grants = taskGrants request.profile authority
          required = case request.profile of Research -> Nothing; Browser -> Just "browser"; Sandbox -> Just "sandbox_exec"; Operations -> Just "maxops_execute"
          key = agentCallKey (object ["receipts" .= receipts, "grants" .= grants]) request
      if maybe False (\name -> not (Map.member name grants)) required
        then pure (Left "requested profile exceeds the parent capability ceiling")
        else do
          previous <-
            query
              "SELECT child_task_id,child_revision,COALESCE(settled_journal_id,first_journal_id),result FROM workflow_agent_steps WHERE parent_task_id=? AND parent_revision=? AND call_key=?"
              (task.taskId, task.revision, key)
          case previous of
            [(child, revision, original, result)] -> do
              work <- loadTask child
              case work of
                Just existing | existing.revision == revision && existing.status /= Cancelled -> do
                  when (isNothing result && existing.status `elem` [Queued, Running, Retrying]) (markWait child)
                  pure (Right (AgentStep child revision original result))
                _ -> pure (Left "cached child generation was invalidated; use a changed objective/input after inspecting its effects")
            [] -> do
              let inputs = object ["context" .= request.inputs, "output_contract" .= request.outputContract, "workflow_agent" .= True]
              admitted <- admitTaskWithin turn Nothing task.owner key request.objective request.profile inputs grants
              case admitted of
                Left failure -> pure (Left (admissionErrorText failure))
                Right child -> do
                  void $
                    execute
                      "INSERT INTO workflow_agent_steps(parent_task_id,parent_revision,call_key,child_task_id,child_revision,first_journal_id) VALUES(?,?,?,?,?,?)"
                      (task.taskId, task.revision, key, child.taskId, child.revision, journal)
                  markWait child.taskId
                  pure (Right (AgentStep child.taskId child.revision journal Nothing))
            _ -> error "workflow step identity is not unique"
    _ -> pure (Left (if pending then "workflow_steering_pending" else "agent() requires a live root task with delegation authority"))
  where
    markWait child = void $ execute "INSERT INTO workflow_agent_waits(turn_id,child_task_id) VALUES(?,?) ON CONFLICT DO NOTHING" (turn, child)

-- Nothing means the child is still executing; a returned report is data.
-- Read and settle under the same parent-generation lock as cancellation.
pollAgentStep :: (WithConnection :> es, IOE :> es) => AgentTurnId -> AgentStep -> Maybe Value -> Int64 -> Eff es (Either Text (Maybe Value))
pollAgentStep turn step contract journal = withTransaction $ do
  allowed <- authorizeWithin turn (ExecutionWork CheckOnly)
  child <- if allowed then loadTask step.childId else pure Nothing
  case child of
    Just task | task.revision == step.childRevision ->
      case task.result of
        Just report | task.status `notElem` [Queued, Running, Retrying] -> do
          let result = agentReport task.status report contract
          if taskIsLive task.status || task.status == Cancelled
            then pure ()
            else
              void $
                execute
                  "UPDATE workflow_agent_steps SET result=?,settled_journal_id=? WHERE child_task_id=? AND child_revision=? AND result IS NULL"
                  (result, journal, step.childId, step.childRevision)
          pure (Right (Just result))
        _ -> pure (Right Nothing)
    _ -> pure (Left "parent or child execution was cancelled, superseded or expired")

endAgentWait :: (WithConnection :> es, IOE :> es) => AgentTurnId -> AgentStep -> Eff es ()
endAgentWait turn step = void $ execute "DELETE FROM workflow_agent_waits WHERE turn_id=? AND child_task_id=?" (turn, step.childId)
