module Max.DB.Browser
  ( BrowserWorkspace (..),
    taskBrowserIdentity,
    acquireBrowserWorkspace,
    beginBrowserOperation,
    finishBrowserOperation,
    browserWorkspace,
    browserGcCandidates,
    retireBrowserWorkspace,
    revokeConversationBrowsers,
    browserCommandOwner,
    resetBrowserWorkspace,
  )
where

import Control.Monad (void)
import Data.Aeson
import Data.Aeson.Types (parseEither)
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime)
import Database.PostgreSQL.Simple (Only (..))
import Effectful
import Effectful.PostgreSQL (WithConnection, execute, query)
import Max.DB.Transaction (withTransaction)
import Max.Platform.Types (PrincipalId (..))
import Max.Turn.Types (AgentTurnId (..))
import OneBot.Types (GroupId (..))

data BrowserWorkspace = BrowserWorkspace
  { bwTask :: !Int64,
    bwRevision :: !Int,
    bwGeneration :: !Int64,
    bwEpoch :: !Int64,
    bwState :: !Text,
    bwCheckpoint :: !(Maybe Text),
    bwLeaseUntil :: !UTCTime,
    bwProfile :: !(Maybe Int64),
    bwProfileCheckpoint :: !(Maybe Text)
  }
  deriving stock (Eq)

instance Show BrowserWorkspace where
  show workspace = "BrowserWorkspace " <> show (workspace.bwTask, workspace.bwGeneration, workspace.bwEpoch, workspace.bwState)

instance FromJSON BrowserWorkspace where
  parseJSON = withObject "browser workspace" $ \fields ->
    BrowserWorkspace
      <$> fields .: "task_id"
      <*> fields .: "revision"
      <*> fields .: "generation"
      <*> fields .: "epoch"
      <*> fields .: "state"
      <*> fields .:? "checkpoint"
      <*> fields .: "lease_until"
      <*> fields .:? "profile_id"
      <*> fields .:? "profile_checkpoint"

taskBrowserIdentity :: (WithConnection :> es, IOE :> es) => AgentTurnId -> GroupId -> Eff es (Maybe Int64)
taskBrowserIdentity turn (GroupId group) = do
  rows <- query "SELECT execution.task_id FROM task_attempts execution JOIN durable_tasks work USING(task_id) JOIN conversations USING(conversation_id) WHERE execution.turn_id=? AND legacy_group_id=?" (turn, group)
  pure $ case rows of [Only identifier] -> Just identifier; _ -> Nothing

acquireBrowserWorkspace :: (WithConnection :> es, IOE :> es) => AgentTurnId -> Text -> Eff es (Either Text BrowserWorkspace)
acquireBrowserWorkspace turn runtime = do
  rows <- query "SELECT max_browser_acquire(?,?)::text" (turn, runtime)
  pure $ case rows of
    [Only encoded] -> do
      value <- either (const (Left "invalid browser lease response")) Right (eitherDecodeStrict' (TE.encodeUtf8 encoded))
      case parseEither (withObject "response" (.: "error")) value of
        Right detail -> Left detail
        Left _ -> either (const (Left "browser lease unavailable")) Right (parseEither parseJSON value)
    _ -> Left "browser lease unavailable"

beginBrowserOperation :: (WithConnection :> es, IOE :> es) => AgentTurnId -> Int64 -> Eff es Bool
beginBrowserOperation turn epoch = do
  rows <- query "SELECT max_browser_begin(?,?)" (turn, epoch)
  pure (rows == [Only True])

finishBrowserOperation :: (WithConnection :> es, IOE :> es) => AgentTurnId -> Int64 -> Maybe Text -> Bool -> Eff es Bool
finishBrowserOperation turn epoch saved healthy = do
  rows <- query "SELECT max_browser_finish(?,?,?,?)" (turn, epoch, saved, healthy)
  pure (rows == [Only True])

browserWorkspace :: (WithConnection :> es, IOE :> es) => Int64 -> Eff es [(Int64, Int64, Text, Maybe Text)]
browserWorkspace identifier = query "SELECT generation,epoch,state,runtime_id FROM browser_workspaces WHERE task_id=?" (Only identifier)

browserGcCandidates :: (WithConnection :> es, IOE :> es) => Int -> Int -> Eff es [(GroupId, Int64, Int64, Bool)]
browserGcCandidates idle grace = do
  rows <-
    query
      "SELECT legacy_group_id,space.task_id,generation,work.revision<>space.revision FROM browser_workspaces space JOIN durable_tasks work USING(task_id) JOIN conversations USING(conversation_id)\
      \ WHERE (space.runtime_id IS NOT NULL OR work.revision<>space.revision OR space.checkpoint IS NOT NULL AND work.deadline<=clock_timestamp()) AND (space.state IN ('revoked','uncertain') OR work.deadline<=clock_timestamp()\
      \ OR work.revision<>space.revision OR work.status IN ('cancelled','budget_exhausted')\
      \ OR work.status IN ('succeeded','partial','failed') AND work.updated_at+make_interval(secs=>?)<=clock_timestamp()\
      \ OR work.status IN ('queued','waiting','retrying') AND space.last_used_at+make_interval(secs=>?)<=clock_timestamp()) ORDER BY space.task_id"
      (grace, idle)
  pure [(GroupId group, task, generation, changed) | (group, task, generation, changed) <- rows]

retireBrowserWorkspace :: (WithConnection :> es, IOE :> es) => Int64 -> Int64 -> Eff es ()
retireBrowserWorkspace identifier generation =
  void $
    execute
      "UPDATE browser_workspaces space SET runtime_id=NULL,owner_turn_id=NULL,generation=generation+1,epoch=epoch+1,\
      \ state=CASE WHEN work.revision<>space.revision THEN 'cold' WHEN space.state IN ('revoked','uncertain') THEN space.state ELSE 'cold' END,\
      \ checkpoint=CASE WHEN work.revision<>space.revision OR work.status IN ('cancelled','budget_exhausted') OR work.deadline<=clock_timestamp() THEN NULL ELSE checkpoint END,\
      \ profile_id=CASE WHEN work.revision<>space.revision THEN NULL ELSE profile_id END,\
      \ profile_version=CASE WHEN work.revision<>space.revision THEN NULL ELSE profile_version END,revision=work.revision\
      \ FROM durable_tasks work WHERE work.task_id=space.task_id AND space.task_id=? AND generation=?"
      (identifier, generation)

revokeConversationBrowsers :: (WithConnection :> es, IOE :> es) => GroupId -> Eff es ()
revokeConversationBrowsers (GroupId group) = withTransaction $ do
  _ :: [Only Int64] <- query "SELECT conversation_id FROM conversations WHERE legacy_group_id=? FOR UPDATE" (Only group)
  void $
    execute
      "INSERT INTO browser_workspaces(task_id,revision,state) SELECT task_id,revision,'revoked' FROM durable_tasks JOIN conversations USING(conversation_id) WHERE legacy_group_id=?\
      \ ON CONFLICT(task_id) DO UPDATE SET state='revoked',checkpoint=NULL,checkpoint_at=NULL,epoch=browser_workspaces.epoch+1"
      (Only group)

browserCommandOwner :: (WithConnection :> es, IOE :> es) => GroupId -> PrincipalId -> Int64 -> Eff es Bool
browserCommandOwner (GroupId group) (PrincipalId actor) identifier = do
  rows <- query "SELECT EXISTS(SELECT 1 FROM durable_tasks JOIN conversations USING(conversation_id) WHERE legacy_group_id=? AND owner_principal_id=? AND task_id=?)" (group, actor, identifier)
  pure (rows == [Only True])

resetBrowserWorkspace :: (WithConnection :> es, IOE :> es) => Int64 -> Eff es ()
resetBrowserWorkspace identifier =
  void $
    execute
      "UPDATE browser_workspaces space SET state='cold',generation=generation+1,epoch=epoch+1,revision=work.revision,runtime_id=NULL,owner_turn_id=NULL,checkpoint=NULL,checkpoint_at=NULL,profile_id=NULL,profile_version=NULL FROM durable_tasks work WHERE work.task_id=space.task_id AND space.task_id=?"
      (Only identifier)
