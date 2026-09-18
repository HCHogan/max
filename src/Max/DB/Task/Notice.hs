module Max.DB.Task.Notice (loadNotice, noticePublished) where

import Data.Aeson (Result (..), Value (..), fromJSON)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Int (Int64)
import Data.Text (Text)
import Database.PostgreSQL.Simple.Types (Only (..))
import Effectful
import Effectful.PostgreSQL (WithConnection, query)
import Max.DB.Task.Authorization (authorizeWithin)
import Max.DB.Task.Frontend (frontendWorkWaitingWithin)
import Max.DB.Transaction (withTransaction)
import Max.Execution.Types (ExecutionStep (ExecutionCheckpoint))
import Max.Task.Notice
import Max.Turn.Types (AgentTurnId)

loadNotice :: (WithConnection :> es, IOE :> es) => AgentTurnId -> Eff es (Maybe TaskNotice)
loadNotice turn = withTransaction $ do
  authorized <- authorizeWithin turn ExecutionCheckpoint
  rows <-
    if authorized
      then
        query
          "SELECT t.conversation_id,t.task_id,n.kind,n.body\
          \ FROM task_notifications n JOIN durable_tasks t USING(task_id) LEFT JOIN task_progress p USING(task_id)\
          \ WHERE n.turn_id=? AND (n.kind='result' OR n.progress_version=p.version)\
          \ AND n.delivered_at IS NULL AND n.superseded_at IS NULL\
          \ AND NOT EXISTS(SELECT 1 FROM messages m WHERE m.agent_turn_id=n.turn_id)"
          (Only turn)
      else pure []
  case rows :: [(Int64, Int64, Text, Value)] of
    [(conversation, task, kind, body)] -> do
      waiting <- frontendWorkWaitingWithin conversation (Just turn)
      if waiting
        then pure Nothing
        else case (kind, body) of
          ("progress", Object fields)
            | Just (String summary) <- KeyMap.lookup "summary" fields ->
                pure (Just (TaskProgress task summary))
          ("result", value) | Success report <- fromJSON value -> pure (Just (TaskResult task report))
          _ -> liftIO (ioError (userError "invalid stored task notice"))
    _ -> pure Nothing

noticePublished :: (WithConnection :> es, IOE :> es) => AgentTurnId -> Eff es Bool
noticePublished turn = do
  rows <- query "SELECT EXISTS(SELECT 1 FROM messages WHERE agent_turn_id=?)" (Only turn)
  pure (rows == [Only True])
