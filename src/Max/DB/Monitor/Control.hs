-- | Monitor definition control and explicit cancellation of admitted work.
module Max.DB.Monitor.Control
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
import Max.DB.ConversationLock (lockConversation)
import Max.DB.Transaction (InTransaction, requireTransaction)
import Max.Monitor.Control
import Max.Monitor.Policy (overlapPolicyText)
import Max.Task.Types (profileName)

-- | Runs within the caller's pinned transaction. Configuration
-- policy is typed at the caller boundary and checked with the locked revision.
controlMonitor :: (InTransaction :> es, WithConnection :> es, IOE :> es) => Int64 -> Int64 -> Bool -> Int64 -> MonitorCommand -> Bool -> Eff es (Either MonitorControlError (MonitorControlReceipt, [Int64]))
controlMonitor group actor administrator ordinal command cancelTasks = do
  requireTransaction
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
            when cancelPending $ do
              -- Publication and control share the monitor lock. Preserve an
              -- output that committed before cancellation, even if its worker
              -- died before acknowledging the occurrence.
              published <-
                execute
                  "UPDATE monitor_fires f SET admission_state='dispatched',dispatched_at=now(), \
                  \ outbound_canonical_message_id=msg.canonical_message_id, \
                  \ claim_owner=NULL,claim_expires_at=NULL,next_attempt_at=NULL,last_error=NULL,parked_at=NULL \
                  \ FROM messages msg WHERE f.monitor_id=? AND f.admission_state='pending' \
                  \ AND f.cancelled_at IS NULL AND msg.monitor_fire_id=f.fire_id"
                  (Only identifier)
              void $ execute "UPDATE monitors SET fire_count=fire_count+? WHERE monitor_id=?" (published, identifier)
              void $
                execute
                  "UPDATE monitor_fires SET cancelled_at=now(),disposition='cancelled',claim_owner=NULL,claim_expires_at=NULL\
                  \ WHERE monitor_id=? AND admission_state='pending' AND cancelled_at IS NULL"
                  (Only identifier)
            tasks <-
              if cancelTasks
                then query "SELECT task_id FROM monitor_fires WHERE monitor_id=? AND task_id IS NOT NULL AND finished_at IS NULL" (Only identifier)
                else pure []
            pure (Right (MonitorControlReceipt nextRevision cancelTasks cancelPending, [task | Only task <- tasks]))
      | otherwise -> pure (Left MonitorOwnerRequired)
    _ -> pure (Left MonitorNotFound)
  where
    validate revision = \case
      CancelMonitor -> Right (revision, True)
      ConfigureMonitor expected objective _ capacity cancelPending _
        | expected /= revision -> Left MonitorRevisionConflict
        | T.null (T.strip objective) || T.length (T.strip objective) > 40000 || capacity < 1 || capacity > 160 -> Left InvalidMonitorDefinition
        | otherwise -> Right (revision + 1, cancelPending == CancelPending)
