-- | Task admission binds provenance, authority and the request obligation in
-- one transaction. PostgreSQL owns uniqueness; Haskell owns the policy.
module Max.DB.Task.Admission (AdmissionError (..), admitTaskWithin) where

import Control.Monad (void, when)
import Data.Aeson (Value, encode)
import Data.ByteString.Lazy qualified as LBS
import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust, isNothing)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (addUTCTime)
import Database.PostgreSQL.Simple.Types (Only (..))
import Effectful
import Effectful.PostgreSQL (WithConnection, execute, query)
import Max.DB.Task.Authorization
import Max.DB.Task.Record
import Max.Task.Admission (AdmissionError (..))
import Max.Task.Types (TaskProfile, profileName, taskGrants)
import Max.Turn.Types (AgentTurnId)

admitTaskWithin :: (WithConnection :> es, IOE :> es) => AgentTurnId -> Maybe Int64 -> Int64 -> Text -> Text -> TaskProfile -> Value -> Map Text Text -> Eff es (Either AdmissionError TaskRecord)
admitTaskWithin turn message actor key objective profile inputs grants = do
  authorized <- authorizeWithin turn (ExecutionWork CheckOnly)
  sources <- query "SELECT conversation_id,initiator_principal_id FROM agent_turns WHERE turn_id=?" (Only turn)
  case sources :: [(Int64, Maybe Int64)] of
    [(conversation, Just initiator)] | authorized -> do
      repeated <-
        query
          "SELECT work.task_id FROM durable_tasks work WHERE work.admission_key=? AND (work.source_turn_id=?\
          \ OR EXISTS(SELECT 1 FROM task_attempts execution WHERE execution.turn_id=? AND execution.task_id=work.parent_task_id AND execution.revision=work.parent_revision))"
          (key, turn, turn)
      -- Check the authenticated actor even on idempotent replay; an opaque
      -- admission key is not permission to discover another owner's task.
      if initiator /= actor
        then pure (Left InvalidAdmission)
        else case repeated of
          [Only identifier] -> requiredTask identifier
          [] -> do
            provenance <- case message of
              Nothing -> pure True
              Just source -> do
                rows <- query "SELECT EXISTS(SELECT 1 FROM messages WHERE canonical_message_id=? AND conversation_id=?)" (source, conversation)
                pure (rows == [Only True])
            attempt <- loadAttempt turn
            parent <- maybe (pure Nothing) (loadTask . (.taskId)) attempt
            depth <- case parent of
              Nothing -> pure 0
              Just task -> do
                rows <-
                  query
                    "WITH RECURSIVE ancestors AS (SELECT task_id,parent_task_id FROM durable_tasks WHERE task_id=?\
                    \ UNION ALL SELECT work.task_id,work.parent_task_id FROM durable_tasks work JOIN ancestors ON work.task_id=ancestors.parent_task_id) SELECT count(*) FROM ancestors"
                    (Only task.taskId)
                case rows of [Only count] -> pure (count :: Int64); _ -> error "ancestor aggregate missing"
            counts <- query "SELECT count(*) FROM durable_tasks WHERE conversation_id=? AND status IN ('queued','running','waiting','retrying')" (Only conversation)
            let validInput = T.length key >= 1 && T.length key <= 600 && not (T.null (T.strip objective)) && T.length (T.strip objective) <= 40000 && LBS.length (encode inputs) <= 160000
                narrower task = Map.isSubmapOfBy (==) grants task.grants
            if not validInput
              then pure (Left InvalidAdmission)
              else
                if not provenance
                  then pure (Left AdmissionSourceOutsideScope)
                  else
                    if isJust attempt && isNothing parent
                      then pure (Left AdmissionFenced)
                      else
                        if grants /= taskGrants profile grants || not (maybe True narrower parent)
                          then pure (Left AdmissionWidenedAuthority)
                          else
                            if depth > 15
                              then pure (Left AdmissionDepthLimit)
                              else
                                if any (\(Only count) -> (count :: Int64) >= 160) counts
                                  then pure (Left AdmissionQueueFull)
                                  else do
                                    now <- databaseNow
                                    let deadline = min (addUTCTime 3000 now) (maybe (addUTCTime 3000 now) (.deadline) parent)
                                        parentId = (.taskId) <$> parent
                                        rootId = (\task -> fromMaybe task.taskId task.root) <$> parent
                                    inserted <-
                                      query
                                        "INSERT INTO durable_tasks(conversation_id,owner_principal_id,source_turn_id,source_message_id,admission_key,\
                                        \ parent_task_id,parent_revision,root_task_id,objective,profile,inputs,grants,deadline,max_calls,max_rounds,created_at)\
                                        \ VALUES(?,?,?,?,?,?,?,?,?,?,?::jsonb,?::jsonb,?,?,?,?) RETURNING task_id"
                                        ( conversation,
                                          actor,
                                          turn,
                                          message,
                                          key,
                                          parentId,
                                          (.revision) <$> parent,
                                          rootId,
                                          T.strip objective,
                                          profileName profile,
                                          jsonText inputs,
                                          jsonText grants,
                                          deadline,
                                          200 :: Int,
                                          400 :: Int,
                                          now
                                        )
                                    case inserted of
                                      [Only identifier] -> do
                                        void $ execute "INSERT INTO task_revisions(task_id,revision,objective,author_principal_id) VALUES(?,1,?,?)" (identifier, T.strip objective, actor)
                                        when (isJust message && isNothing parent) $
                                          void $
                                            execute
                                              "INSERT INTO conversation_requests(message_id,turn_id,disposition) VALUES(?,?,'delegated')\
                                              \ ON CONFLICT(message_id) DO UPDATE SET disposition='delegated',updated_at=now()"
                                              (message, turn)
                                        requiredTask identifier
                                      _ -> error "task admission did not create a task"
          _ -> error "task admission key is not unique"
    _ -> pure (Left AdmissionFenced)
  where
    requiredTask identifier = loadTask identifier >>= maybe (error "admitted task missing") (pure . Right)
