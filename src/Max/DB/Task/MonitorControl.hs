-- | Monitor definition control and explicit cancellation of admitted work.
module Max.DB.Task.MonitorControl
  ( MonitorCommand (..),
    MonitorControlError (..),
    MonitorControlReceipt (..),
    controlMonitor,
  )
where

import Control.Monad (forM_, void, when)
import Data.Int (Int64)
import Data.Text qualified as T
import Database.PostgreSQL.Simple.Types (Only (..))
import Effectful
import Effectful.PostgreSQL (WithConnection, execute, query)
import Max.DB.Task.Control (controlTask)
import Max.DB.Task.Record (lockConversation)
import Max.Monitor.Control
import Max.Monitor.Policy (overlapPolicyText)
import Max.Task.State (TaskOperation (Cancel))
import Max.Task.Types (profileName)

-- | Runs within the caller's pinned transaction. Configuration
-- policy is typed at the caller boundary and checked with the locked revision.
controlMonitor :: (WithConnection :> es, IOE :> es) => Int64 -> Int64 -> Bool -> Int64 -> MonitorCommand -> Bool -> Eff es (Either MonitorControlError MonitorControlReceipt)
controlMonitor group actor administrator ordinal command cancelTasks = do
  _ <- lockConversation group
  definitions <-
    query
      "SELECT monitor_id,armed_by_principal_id,definition_revision FROM monitors monitor JOIN conversations USING(conversation_id)\
      \ WHERE legacy_group_id=? AND monitor_ordinal=? FOR UPDATE OF monitor"
      (group, ordinal)
  case definitions :: [(Int64, Maybe Int64, Int)] of
    [(identifier, owner, revision)]
      | administrator || owner == Just actor -> case validate revision command of
          Left failure -> pure (Left failure)
          Right (nextRevision, cancelPending) -> do
            case command of
              CancelMonitor ->
                void $
                  execute
                    "UPDATE monitors SET status='cancelled',cancelled_at=now(),next_fire_at=NULL,updated_at=now() WHERE monitor_id=?"
                    (Only identifier)
              ConfigureMonitor _ objective coalesce capacity _ profile -> do
                void $
                  execute
                    "UPDATE monitors SET goal_text=?,definition_revision=?,overlap_policy=?,queue_limit=?,updated_at=now() WHERE monitor_id=?"
                    (T.strip objective, nextRevision, overlapPolicyText coalesce, capacity, identifier)
                forM_ profile $ \(capability, changeOnly) ->
                  void $
                    execute
                      "UPDATE monitors SET task_profile=?,change_only=? WHERE monitor_id=?"
                      (profileName capability, changeOnly, identifier)
            when cancelPending $
              void $
                execute
                  "UPDATE monitor_fires SET cancelled_at=now(),disposition='cancelled',claim_owner=NULL,claim_expires_at=NULL\
                  \ WHERE monitor_id=? AND admission_state='pending' AND cancelled_at IS NULL"
                  (Only identifier)
            when cancelTasks $ do
              tasks <-
                query
                  "SELECT work.task_id FROM durable_tasks work JOIN monitor_fires fire ON fire.fire_id=work.monitor_fire_id\
                  \ WHERE fire.monitor_id=? AND work.status IN ('queued','running','waiting','retrying') ORDER BY work.task_id"
                  (Only identifier)
              forM_ (tasks :: [Only Int64]) $ \(Only task) -> do
                result <- controlTask group actor True task Cancel Nothing Nothing "monitor controller explicitly cancelled admitted work"
                -- The definition owner has been checked under the same lock.
                -- Failing to cancel any child rolls back the definition too.
                either (error . ("monitor task cancellation invariant: " <>) . show) (const (pure ())) result
            pure (Right (MonitorControlReceipt nextRevision cancelTasks cancelPending))
      | otherwise -> pure (Left MonitorOwnerRequired)
    _ -> pure (Left MonitorNotFound)
  where
    validate revision = \case
      CancelMonitor -> Right (revision, True)
      ConfigureMonitor expected objective _ capacity cancelPending _
        | expected /= revision -> Left MonitorRevisionConflict
        | T.null (T.strip objective) || T.length (T.strip objective) > 40000 || capacity < 1 || capacity > 160 -> Left InvalidMonitorDefinition
        | otherwise -> Right (revision + 1, cancelPending == CancelPending)
