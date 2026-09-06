-- | Explicit durable settlement. Every function in this module runs inside
-- its caller's pinned transaction, with the conversation already locked.
-- A terminal checkpoint and all resulting obligations commit together.
module Max.DB.Task.Settlement
  ( settleTurn,
    completeTask,
    cancelDescendants,
    revokeTaskBrowser,
  )
where

import Control.Monad (forM_, unless, void, when)
import Data.Aeson (Value, toJSON)
import Data.Int (Int64)
import Data.Maybe (fromMaybe, isNothing)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (addUTCTime)
import Database.PostgreSQL.Simple.Types (Only (..))
import Effectful
import Effectful.PostgreSQL (WithConnection, execute, query)
import Max.DB.Task.Record
import Max.Task.State
import Max.Task.Types (taskHandle)
import Max.Turn.Types (AgentTurnId)

-- | Called only after the caller successfully changed the turn from live to
-- terminal. Repeated terminal writes must not settle the same attempt twice.
settleTurn :: (WithConnection :> es, IOE :> es) => AgentTurnId -> Bool -> Maybe Text -> Bool -> Eff es ()
settleTurn turn successful abortReason frontendManaged = do
  attempt <- loadAttempt turn
  forM_ attempt $ \execution -> do
    current <- loadTask execution.taskId
    now <- databaseNow
    forM_ current $ \task -> when
      (task.status == Running && task.revision == execution.revision && task.attempt == execution.attempt && execution.leaseUntil > now)
      $ do
        budgets <-
          query
            "SELECT EXISTS(SELECT 1 FROM durable_tasks WHERE task_id IN (?,?) AND (calls_reserved>=max_calls OR rounds_reserved>=max_rounds))"
            (task.taskId, fromMaybe task.taskId task.root)
        pending <-
          query
            "SELECT EXISTS(SELECT 1 FROM task_events WHERE task_id=? AND event_id>? AND kind<>'child_progress')"
            (task.taskId, execution.seenEvent)
        unknown <-
          query
            "SELECT EXISTS(SELECT 1 FROM execution_journal journal JOIN task_attempts history USING(turn_id) WHERE history.task_id=? AND journal.state IN ('started','outcome-unknown'))"
            (Only task.taskId)
        let decision =
              decideSettlement
                SettlementFacts
                  { now,
                    deadline = task.deadline,
                    attempt = task.attempt,
                    retryCount = task.retryCount,
                    budgetExhausted = budgets == [Only True],
                    retryable = execution.retryable,
                    ambiguousEffects = unknown == [Only True],
                    pendingInput = pending == [Only True],
                    report = execution.report,
                    abortReason
                  }
        void $
          execute
            "UPDATE durable_tasks SET consumed_event=GREATEST(consumed_event,?),next_attempt_at=?,\
            \ retry_count=retry_count+?,last_error=? WHERE task_id=?"
            ( execution.seenEvent,
              decision.retryAt,
              if decision.status == Retrying then (1 :: Int) else 0,
              if decision.status == Retrying then Just decision.report.summary else Nothing,
              task.taskId
            )
        completeTask task decision.status (Just decision.report)
        when (decision.status == Retrying) $
          void $
            execute
              "INSERT INTO task_events(task_id,revision,kind,body) VALUES(?,?,'retry_scheduled',?)"
              (task.taskId, task.revision, T.take 60000 (jsonText decision.report))
  settleNotification turn successful abortReason
  when frontendManaged $ do
    receipts <- query "SELECT EXISTS(SELECT 1 FROM messages WHERE agent_turn_id=?)" (Only turn)
    outcomes <- query "SELECT disposition,reply FROM request_outcomes WHERE turn_id=?" (Only turn)
    let outcome = case outcomes :: [(Text, Text)] of
          [(decision, reply)] -> (fromMaybe RequestWaiting (parseDisposition decision), Just reply)
          _ -> (RequestWaiting, Nothing)
        disposition = if successful && receipts == [Only True] then fst outcome else RequestFailed
        reason = T.take 5000 (fromMaybe (fromMaybe "No explicit request disposition was recorded" abortReason) (snd outcome))
    void $
      execute
        "UPDATE conversation_requests SET disposition=?,reason=?,updated_at=now() WHERE turn_id=? AND disposition<>'delegated'"
        (dispositionText disposition, reason, turn)
    -- A delegated request retains its disposition, but still gets the
    -- frontend's explanatory checkpoint, as did the former settlement.
    void $
      execute
        "UPDATE conversation_requests SET reason=?,updated_at=now() WHERE turn_id=? AND disposition='delegated'"
        (reason, turn)
    void $ execute "DELETE FROM conversation_frontends WHERE turn_id=?" (Only turn)
    void $ execute "NOTIFY max_dispatch_work, '1'" ()
    void $ execute "NOTIFY max_task_work, '1'" ()

settleNotification :: (WithConnection :> es, IOE :> es) => AgentTurnId -> Bool -> Maybe Text -> Eff es ()
settleNotification turn successful abortReason = do
  receipts <- query "SELECT EXISTS(SELECT 1 FROM messages WHERE agent_turn_id=?)" (Only turn)
  when (successful && receipts == [Only True]) $
    void $
      execute
        "UPDATE task_notifications SET delivered_at=now() WHERE turn_id=? AND superseded_at IS NULL AND delivered_at IS NULL"
        (Only turn)
  pending <-
    query
      "SELECT notification_id,attempts FROM task_notifications WHERE turn_id=? AND delivered_at IS NULL AND superseded_at IS NULL FOR UPDATE"
      (Only turn)
  now <- databaseNow
  forM_ (pending :: [(Int64, Int)]) $ \(identifier, attempts) ->
    void $
      execute
        "UPDATE task_notifications SET next_attempt_at=?,last_error=? WHERE notification_id=?"
        ( addUTCTime (fromIntegral (retryDelaySeconds (attempts - 1))) now,
          fromMaybe "notification ended without an output receipt" abortReason,
          identifier
        )
  delivered <-
    query
      "SELECT work.task_id FROM task_notifications notice JOIN durable_tasks work USING(task_id)\
      \ WHERE notice.turn_id=? AND notice.delivered_at IS NOT NULL AND notice.kind='result'\
      \ AND notice.superseded_at IS NULL AND notice.revision=work.revision AND notice.attempt=work.attempt AND work.monitor_fire_id IS NULL"
      (Only turn)
  forM_ (delivered :: [Only Int64]) $ \(Only identifier) -> do
    task <- loadTask identifier
    forM_ task $ \work -> do
      let disposition = case work.status of
            Succeeded -> RequestAnswered
            Partial -> RequestWaiting
            Waiting -> RequestWaiting
            _ -> RequestFailed
      void $
        execute
          "UPDATE conversation_requests request SET disposition=?,reason=?,updated_at=now()\
          \ WHERE (request.message_id=? OR EXISTS(SELECT 1 FROM task_events WHERE task_id=? AND source_message_id=request.message_id))\
          \ AND NOT EXISTS(SELECT 1 FROM durable_tasks other WHERE other.source_message_id=request.message_id AND other.status IN ('queued','running','waiting','retrying'))"
          (dispositionText disposition, T.take 5000 . (.summary) <$> work.result, work.sourceMessage, work.taskId)

completeTask :: (WithConnection :> es, IOE :> es) => TaskRecord -> TaskStatus -> Maybe TaskReport -> Eff es ()
completeTask previous status report = do
  void $
    execute
      "UPDATE durable_tasks SET status=?,result=?::jsonb,updated_at=now() WHERE task_id=?"
      (taskStatusText status, jsonText <$> report, previous.taskId)
  let current = previous {status, result = report}
  when (status /= previous.status) $ do
    when (status == Cancelled || status == BudgetExhausted) $ revokeTaskBrowser previous.taskId
    when (status == Waiting || not (taskIsLive status)) $ do
      void $
        execute
          "UPDATE task_notifications SET superseded_at=now() WHERE task_id=? AND kind='progress' AND delivered_at IS NULL AND superseded_at IS NULL"
          (Only previous.taskId)
      when (status /= Waiting) $ cancelDescendants previous.taskId "parent task ended"
      routeCompletion current

-- | Revoke the complete subtree before routing its results. No child result
-- may accidentally wake a sibling/parent already being cancelled.
cancelDescendants :: (WithConnection :> es, IOE :> es) => Int64 -> Text -> Eff es ()
cancelDescendants parent reason = do
  rows <-
    query
      "WITH RECURSIVE descendants AS (SELECT task_id FROM durable_tasks WHERE parent_task_id=?\
      \ UNION ALL SELECT child.task_id FROM durable_tasks child JOIN descendants ON child.parent_task_id=descendants.task_id)\
      \ UPDATE durable_tasks SET status='cancelled',result=?::jsonb,updated_at=now()\
      \ WHERE task_id IN (SELECT task_id FROM descendants) AND status IN ('queued','running','waiting','retrying') RETURNING task_id"
      (parent, jsonText (TaskReport ReportCancelled reason [] [] Nothing Nothing))
  forM_ (rows :: [Only Int64]) $ \(Only identifier) -> do
    revokeTaskBrowser identifier
    void $ execute "UPDATE task_attempts SET lease_until=clock_timestamp() WHERE task_id=?" (Only identifier)
    void $
      execute
        "UPDATE task_notifications SET superseded_at=now() WHERE task_id=? AND kind='progress' AND delivered_at IS NULL AND superseded_at IS NULL"
        (Only identifier)
    task <- loadTask identifier
    forM_ task routeCompletion

revokeTaskBrowser :: (WithConnection :> es, IOE :> es) => Int64 -> Eff es ()
revokeTaskBrowser identifier =
  void $
    execute
      "UPDATE browser_workspaces SET state='revoked',epoch=epoch+1,checkpoint=NULL,checkpoint_at=NULL WHERE task_id=?"
      (Only identifier)

routeCompletion :: (WithConnection :> es, IOE :> es) => TaskRecord -> Eff es ()
routeCompletion task = case task.parent of
  Just parent -> do
    let body = T.take 60000 (taskHandle task.taskId <> " revision " <> T.pack (show task.revision) <> ": " <> maybe (taskStatusText task.status) jsonText task.result)
    void $
      execute
        "INSERT INTO task_events(task_id,revision,kind,body) SELECT task_id,revision,'child_result',? FROM durable_tasks\
        \ WHERE task_id=? AND revision=? AND status IN ('running','queued','waiting','retrying')"
        (body, parent, task.parentRevision)
    void $
      execute
        "UPDATE durable_tasks SET status='queued',updated_at=now() WHERE task_id=? AND revision=? AND status='waiting'"
        (parent, task.parentRevision)
  Nothing -> do
    children <-
      query
        "SELECT EXISTS(SELECT 1 FROM durable_tasks WHERE parent_task_id=? AND status IN ('queued','running','waiting','retrying'))"
        (Only task.taskId)
    when (task.status == Cancelled && isNothing task.monitorFire) $
      void $
        execute
          "UPDATE conversation_requests SET disposition='cancelled',reason='task cancelled',updated_at=now()\
          \ WHERE message_id=? AND NOT EXISTS(SELECT 1 FROM durable_tasks WHERE source_message_id=? AND status IN ('queued','running','waiting','retrying'))"
          (task.sourceMessage, task.sourceMessage)
    quiet <- if task.status == Waiting && children == [Only True] then pure True else suppressMonitorNotice task
    unless quiet $ do
      let body = fromMaybe (TaskReport (terminalReport task.status) (taskStatusText task.status) [] [] Nothing Nothing) task.result
      void $
        execute
          "INSERT INTO task_notifications(task_id,revision,attempt,body)\
          \ SELECT ?,?,?,?::jsonb WHERE NOT EXISTS(SELECT 1 FROM task_notifications WHERE task_id=? AND revision=? AND attempt=? AND kind='result')"
          (task.taskId, task.revision, task.attempt, jsonText body, task.taskId, task.revision, task.attempt)

terminalReport :: TaskStatus -> ReportStatus
terminalReport = \case
  Succeeded -> ReportSucceeded
  Partial -> ReportPartial
  Waiting -> ReportWaiting
  Failed -> ReportFailed
  Cancelled -> ReportCancelled
  BudgetExhausted -> ReportBudgetExhausted
  _ -> error "non-terminal task cannot produce a result notification"

suppressMonitorNotice :: (WithConnection :> es, IOE :> es) => TaskRecord -> Eff es Bool
suppressMonitorNotice task = case task.monitorFire of
  Nothing -> pure False
  Just fire -> do
    definitions <-
      query
        "SELECT current.monitor_id,current.definition_revision,COALESCE((current.definition_snapshot->>'change_only')::boolean,definition.change_only)\
        \ FROM monitor_fires current JOIN monitors definition USING(monitor_id) WHERE current.fire_id=?"
        (Only fire)
    case definitions :: [(Int64, Int, Bool)] of
      [(monitor, revision, True)]
        | task.status == Failed || task.status == BudgetExhausted -> do
            now <- databaseNow
            rows <-
              query
                "SELECT EXISTS(SELECT 1 FROM monitor_fires fire JOIN durable_tasks previous ON previous.task_id=fire.task_id\
                \ JOIN task_notifications notice ON notice.task_id=previous.task_id\
                \ WHERE fire.monitor_id=? AND fire.definition_revision=? AND previous.task_id<>? AND notice.body->>'status'=? AND previous.updated_at>?)"
                (monitor, revision, task.taskId, taskStatusText task.status, addUTCTime (-3600) now)
            pure (rows == [Only True])
        | otherwise -> do
            previous <-
              query
                "SELECT previous.task_id FROM monitor_fires fire JOIN durable_tasks previous ON previous.task_id=fire.task_id\
                \ WHERE fire.monitor_id=? AND fire.definition_revision=? AND previous.task_id<>?\
                \ AND previous.status IN ('succeeded','partial','waiting','failed','budget_exhausted')\
                \ ORDER BY previous.updated_at DESC,previous.task_id DESC LIMIT 1"
                (monitor, revision, task.taskId)
            case previous of
              [Only identifier] -> do
                old <- loadTask identifier
                pure $ maybe False (\prior -> task.status == prior.status && observationOf task.result == observationOf prior.result) old
              _ -> pure False
      _ -> pure False
  where
    observationOf :: Maybe TaskReport -> Maybe Value
    observationOf = fmap (\report -> fromMaybe (toJSON report) report.observation)
