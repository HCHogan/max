-- | Facts read under the conversation lock. Domain transitions live in
-- Haskell; this module owns row decoding and the common lock order.
module Max.DB.Task.Record
  ( TaskRecord (..),
    AttemptRecord (..),
    loadTask,
    loadAttempt,
    lockTurnConversation,
    lockTaskConversation,
    lockConversation,
    databaseNow,
    jsonText,
  )
where

import Data.Aeson (ToJSON, Value, encode)
import Data.ByteString.Lazy qualified as LBS
import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime)
import Database.PostgreSQL.Simple.FromRow (FromRow (..), field)
import Database.PostgreSQL.Simple.Types (Only (..))
import Effectful
import Effectful.PostgreSQL (WithConnection, query)
import Max.DB.Codec (enumField, jsonField)
import Max.DB.ConversationLock (lockConversation, lockTaskConversation, lockTurnConversation)
import Max.Task.State
import Max.Task.Types (TaskProfile, parseProfile)
import Max.Turn.Types (AgentTurnId)

data TaskRecord = TaskRecord
  { taskId :: !Int64,
    conversationId :: !Int64,
    owner :: !Int64,
    sourceTurn :: !AgentTurnId,
    sourceMessage :: !(Maybe Int64),
    parent :: !(Maybe Int64),
    parentRevision :: !(Maybe Int),
    root :: !(Maybe Int64),
    monitorFire :: !(Maybe Int64),
    revision :: !Int,
    objective :: !Text,
    profile :: !TaskProfile,
    inputs :: !Value,
    grants :: !(Map Text Text),
    status :: !TaskStatus,
    result :: !(Maybe TaskReport),
    calls :: !Int,
    rounds :: !Int,
    maxCalls :: !Int,
    maxRounds :: !Int,
    attempt :: !Int,
    consumedEvent :: !Int64,
    deadline :: !UTCTime,
    retryCount :: !Int
  }
  deriving stock (Show, Eq)

instance FromRow TaskRecord where
  fromRow =
    TaskRecord
      <$> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> enumField parseProfile
      <*> jsonField
      <*> jsonField
      <*> enumField parseTaskStatus
      <*> jsonField
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field

-- | The caller holds the conversation lock before locking work. Parent,
-- child, frontend and notification transitions therefore share one order.
loadTask :: (WithConnection :> es, IOE :> es) => Int64 -> Eff es (Maybe TaskRecord)
loadTask identifier = do
  rows <-
    query
      "SELECT task_id,conversation_id,owner_principal_id,source_turn_id,source_message_id,\
      \ parent_task_id,parent_revision,root_task_id,monitor_fire_id,revision,objective,profile,\
      \ inputs::text,grants::text,status,COALESCE(result,'null'::jsonb)::text,\
      \ calls_reserved,rounds_reserved,max_calls,max_rounds,attempt,consumed_event,deadline,retry_count\
      \ FROM durable_tasks WHERE task_id=? FOR UPDATE"
      (Only identifier)
  pure $ case rows of [row] -> Just row; _ -> Nothing

data AttemptRecord = AttemptRecord
  { taskId :: !Int64,
    revision :: !Int,
    attempt :: !Int,
    owner :: !Text,
    leaseUntil :: !UTCTime,
    seenEvent :: !Int64,
    report :: !(Maybe TaskReport),
    retryable :: !Bool
  }
  deriving stock (Show, Eq)

instance FromRow AttemptRecord where
  fromRow = AttemptRecord <$> field <*> field <*> field <*> field <*> field <*> field <*> jsonField <*> field

loadAttempt :: (WithConnection :> es, IOE :> es) => AgentTurnId -> Eff es (Maybe AttemptRecord)
loadAttempt turn = do
  rows <-
    query
      "SELECT task_id,revision,attempt,owner,lease_until,seen_event,COALESCE(report,'null'::jsonb)::text,retryable FROM task_attempts WHERE turn_id=? FOR UPDATE"
      (Only turn)
  pure $ case rows of [row] -> Just row; _ -> Nothing

databaseNow :: (WithConnection :> es, IOE :> es) => Eff es UTCTime
databaseNow = do
  rows <- query "SELECT clock_timestamp()" ()
  case rows of [Only now] -> pure now; _ -> error "database clock missing"

jsonText :: (ToJSON a) => a -> Text
jsonText = TE.decodeUtf8 . LBS.toStrict . encode
