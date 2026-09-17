module Max.DB.Task.Control (controlTask) where

import Control.Monad (void, when)
import Data.Maybe (isJust)
import Data.Text qualified as T
import Database.PostgreSQL.Simple.Types (Only (..))
import Effectful
import Effectful.PostgreSQL (WithConnection, execute, query)
import Max.DB.Task.Record
import Max.DB.Task.Settlement
import Max.DB.Transaction (InTransaction, requireTransaction)
import Max.Platform.Types
  ( CanonicalMessageId (..),
    PrincipalId (..),
  )
import Max.Task.State
import OneBot.Types (GroupId (..))

-- | The caller owns the transaction. The conversation lock serializes CAS,
-- provenance, child cancellation, browser revocation and request transfer.
controlTask :: (InTransaction :> es, WithConnection :> es, IOE :> es) => GroupId -> PrincipalId -> Bool -> DurableTaskId -> TaskCommand -> Maybe CanonicalMessageId -> Eff es (Either TaskControlError TaskControlReceipt)
controlTask (GroupId group) (PrincipalId actor) administrator (DurableTaskId identifier) command sourceMessage = do
  let operation = commandOperation command
      note = commandNote command
      source = (.unCanonicalMessageId) <$> sourceMessage
  requireTransaction
  locked <- lockConversation group
  tasks <-
    if locked
      then
        query
          "SELECT task_id FROM durable_tasks JOIN conversations USING(conversation_id) WHERE task_id=? AND legacy_group_id=?"
          (identifier, group)
      else pure []
  current <- if tasks == [Only identifier] then loadTask identifier else pure Nothing
  case current of
    Nothing -> pure (Left TaskNotFound)
    Just task -> do
      provenance <- case source of
        Nothing -> pure True
        Just message -> do
          rows <-
            query
              "SELECT EXISTS(SELECT 1 FROM messages WHERE canonical_message_id=? AND conversation_id=? AND author_principal_id=?)"
              (message, task.conversationId, actor)
          pure (rows == [Only True])
      duplicate <- query "SELECT EXISTS(SELECT 1 FROM task_events WHERE task_id=? AND source_message_id=?)" (identifier, source)
      let receipt = TaskControlReceipt identifier task.revision
          trimmed = T.strip note
          facts = TaskControlFacts task.status task.revision (administrator || actor == task.owner) provenance (isJust source && duplicate == [Only True])
      case decideTaskControl command facts of
        Left failure -> pure (Left failure)
        Right ReplayControl -> pure (Right receipt)
        Right ApplyControl -> do
          void $
            execute
              "INSERT INTO task_events(task_id,revision,kind,author_principal_id,source_message_id,body) VALUES(?,?,?,?,?,?)"
              (identifier, task.revision, taskOperationText operation, actor, source, trimmed)
          when (isJust source) $
            void $
              execute
                "INSERT INTO conversation_requests(message_id,disposition) VALUES(?,?) ON CONFLICT(message_id) DO NOTHING"
                (source, dispositionText (if operation == Cancel then RequestCancelled else RequestDelegated))
          case operation of
            Replace -> do
              void $
                execute
                  "UPDATE durable_tasks SET revision=revision+1,objective=?,status='queued',result=NULL,next_attempt_at=NULL,last_error=NULL,updated_at=now() WHERE task_id=?"
                  (trimmed, identifier)
              void $
                execute
                  "INSERT INTO task_revisions(task_id,revision,objective,author_principal_id) VALUES(?,?,?,?)"
                  (identifier, task.revision + 1, trimmed, actor)
              revokeTaskBrowser identifier
              cancelDescendants identifier "parent task replaced"
            Cancel -> completeTask task Cancelled (Just (TaskReport ReportCancelled trimmed [] [] Nothing Nothing Nothing))
            Steer -> completeTask task (if task.status `elem` [Running, Retrying] then task.status else Queued) task.result
          when (operation /= Steer) $ void $ execute "UPDATE task_attempts SET lease_until=clock_timestamp() WHERE task_id=?" (Only identifier)
          pure (Right (TaskControlReceipt identifier (task.revision + if operation == Replace then 1 else 0)))
