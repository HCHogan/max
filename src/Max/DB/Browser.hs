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
    revokeProfileWorkspaces,
  )
where

import Control.Monad (void)
import Data.Int (Int64)
import Data.Maybe (isNothing)
import Data.Text (Text)
import Data.Time (UTCTime)
import Database.PostgreSQL.Simple (Only (..))
import Database.PostgreSQL.Simple.FromRow (FromRow (..), field)
import Effectful
import Effectful.PostgreSQL (WithConnection, execute, query)
import Max.Browser.State
import Max.DB.Codec (enumField)
import Max.DB.Task.Authorization
import Max.DB.Task.Record qualified as Task
import Max.DB.Transaction (withTransaction)
import Max.Platform.Types (PrincipalId (..))
import Max.Task.State (TaskStatus (BudgetExhausted, Cancelled))
import Max.Turn.Types (AgentTurnId (..))
import OneBot.Types (GroupId (..))

data BrowserWorkspace = BrowserWorkspace
  { bwTask :: !Int64,
    bwRevision :: !Int,
    bwGeneration :: !Int64,
    bwEpoch :: !Int64,
    bwState :: !WorkspaceState,
    bwCheckpoint :: !(Maybe Text),
    bwLeaseUntil :: !UTCTime,
    bwProfile :: !(Maybe Int64),
    bwProfileCheckpoint :: !(Maybe Text)
  }
  deriving stock (Eq)

instance Show BrowserWorkspace where
  show workspace = "BrowserWorkspace " <> show (workspace.bwTask, workspace.bwGeneration, workspace.bwEpoch, workspace.bwState)

data WorkspaceRow = WorkspaceRow
  { revision :: !Int,
    generation :: !Int64,
    epoch :: !Int64,
    state :: !WorkspaceState,
    runtime :: !(Maybe Text),
    checkpoint :: !(Maybe Text),
    profile :: !(Maybe Int64),
    profileVersion :: !(Maybe Int64)
  }
  deriving stock (Show)

instance FromRow WorkspaceRow where
  fromRow = WorkspaceRow <$> field <*> field <*> field <*> enumField parseWorkspaceState <*> field <*> field <*> field <*> field

loadWorkspace :: (WithConnection :> es, IOE :> es) => Int64 -> Eff es (Maybe WorkspaceRow)
loadWorkspace identifier = do
  rows <- query "SELECT revision,generation,epoch,state,runtime_id,checkpoint,profile_id,profile_version FROM browser_workspaces WHERE task_id=? FOR UPDATE" (Only identifier)
  pure $ case rows of [row] -> Just row; _ -> Nothing

taskBrowserIdentity :: (WithConnection :> es, IOE :> es) => AgentTurnId -> GroupId -> Eff es (Maybe Int64)
taskBrowserIdentity turn (GroupId group) = do
  rows <- query "SELECT execution.task_id FROM task_attempts execution JOIN durable_tasks work USING(task_id) JOIN conversations USING(conversation_id) WHERE execution.turn_id=? AND legacy_group_id=?" (turn, group)
  pure $ case rows of [Only identifier] -> Just identifier; _ -> Nothing

acquireBrowserWorkspace :: (WithConnection :> es, IOE :> es) => AgentTurnId -> Text -> Eff es (Either WorkspaceError BrowserWorkspace)
acquireBrowserWorkspace turn runtime = withTransaction $ do
  authorized <- authorizeWithin turn (ExecutionWork CheckOnly)
  attempt <- Task.loadAttempt turn
  if not authorized
    then pure (Left WorkspaceFenced)
    else case attempt of
      Nothing -> pure (Left WorkspaceUnavailable)
      Just execution -> do
        current <- Task.loadTask execution.taskId
        case current of
          Nothing -> pure (Left WorkspaceUnavailable)
          Just task -> do
            snapshots <-
              query
                "SELECT (definition_snapshot->>'browser_profile_id')::bigint,(definition_snapshot->>'browser_profile_version')::bigint FROM monitor_fires WHERE fire_id=?"
                (Only task.monitorFire)
            let (profile, version) = case snapshots :: [(Maybe Int64, Maybe Int64)] of [pair] -> pair; _ -> (Nothing, Nothing)
            void $
              execute
                "INSERT INTO browser_workspaces(task_id,revision,profile_id,profile_version) VALUES(?,?,?,?) ON CONFLICT DO NOTHING"
                (task.taskId, task.revision, profile, version)
            loaded <- loadWorkspace task.taskId
            case loaded of
              Nothing -> pure (Left WorkspaceUnavailable)
              Just workspace -> do
                profiles <-
                  query
                    "SELECT checkpoint FROM browser_profiles WHERE profile_id=? AND version=? AND NOT revoked AND principal_id=? AND conversation_id=?"
                    (workspace.profile, workspace.profileVersion, task.owner, task.conversationId)
                let profileValid = isNothing workspace.profile || length (profiles :: [Only (Maybe Text)]) == 1
                case decideAcquisition workspace.state profileValid (workspace.revision /= task.revision) (workspace.runtime /= Just runtime) of
                  Left failure -> do
                    case failure of
                      WorkspaceUnknown -> void $ execute "UPDATE browser_workspaces SET state='uncertain' WHERE task_id=?" (Only task.taskId)
                      ProfileRevoked -> void $ execute "UPDATE browser_workspaces SET state='revoked',epoch=epoch+1,checkpoint=NULL,checkpoint_at=NULL WHERE task_id=?" (Only task.taskId)
                      _ -> pure ()
                    pure (Left failure)
                  Right decision -> do
                    case decision of
                      ResetRevision ->
                        void $
                          execute
                            "UPDATE browser_workspaces SET revision=?,generation=generation+1,state='cold',checkpoint=NULL,checkpoint_at=NULL,owner_turn_id=NULL,runtime_id=NULL,profile_id=NULL,profile_version=NULL WHERE task_id=?"
                            (task.revision, task.taskId)
                      RestoreRuntime ->
                        void $
                          execute
                            "UPDATE browser_workspaces SET generation=generation+1,state='cold',owner_turn_id=NULL,runtime_id=NULL WHERE task_id=?"
                            (Only task.taskId)
                      ReuseWorkspace -> pure ()
                    void $
                      execute
                        "UPDATE browser_workspaces SET epoch=epoch+1,owner_turn_id=?,runtime_id=?,last_used_at=clock_timestamp() WHERE task_id=?"
                        (turn, runtime, task.taskId)
                    updated <- loadWorkspace task.taskId
                    pure $ case updated of
                      Nothing -> Left WorkspaceUnavailable
                      Just owned ->
                        Right
                          BrowserWorkspace
                            { bwTask = task.taskId,
                              bwRevision = owned.revision,
                              bwGeneration = owned.generation,
                              bwEpoch = owned.epoch,
                              bwState = owned.state,
                              bwCheckpoint = owned.checkpoint,
                              bwLeaseUntil = execution.leaseUntil,
                              bwProfile = owned.profile,
                              bwProfileCheckpoint = if isNothing owned.profile then Nothing else case profiles of [Only saved] -> saved; _ -> Nothing
                            }

beginBrowserOperation :: (WithConnection :> es, IOE :> es) => AgentTurnId -> Int64 -> Eff es Bool
beginBrowserOperation turn epoch = withTransaction $ do
  authorized <- authorizeWithin turn (ExecutionWork CheckOnly)
  if not authorized
    then pure False
    else do
      changed <- execute "UPDATE browser_workspaces SET state='busy',last_used_at=clock_timestamp() WHERE owner_turn_id=? AND epoch=? AND state IN ('hot','cold')" (turn, epoch)
      pure (changed == 1)

finishBrowserOperation :: (WithConnection :> es, IOE :> es) => AgentTurnId -> Int64 -> Maybe Text -> Bool -> Eff es Bool
finishBrowserOperation turn epoch saved healthy = withTransaction $ do
  authorized <- authorizeWithin turn (ExecutionWork CheckOnly)
  changed <-
    if healthy && authorized
      then
        execute
          "UPDATE browser_workspaces SET state='hot',checkpoint=COALESCE(?,checkpoint),checkpoint_at=CASE WHEN ?::text IS NULL THEN checkpoint_at ELSE clock_timestamp() END,last_used_at=clock_timestamp() WHERE owner_turn_id=? AND epoch=? AND state='busy'"
          (saved, saved, turn, epoch)
      else execute "UPDATE browser_workspaces SET state='uncertain',last_used_at=clock_timestamp() WHERE owner_turn_id=? AND epoch=? AND state='busy'" (turn, epoch)
  pure (changed == 1 && authorized)

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
retireBrowserWorkspace identifier generation = withTransaction $ do
  _ <- Task.lockTaskConversation identifier
  task <- Task.loadTask identifier
  workspace <- loadWorkspace identifier
  now <- Task.databaseNow
  case (task, workspace) of
    (Just work, Just space) | space.generation == generation -> do
      let revised = work.revision /= space.revision
          state
            | revised = Cold
            | space.state `elem` [Revoked, Uncertain] = space.state
            | otherwise = Cold
          wipe = revised || work.status `elem` [Cancelled, BudgetExhausted] || work.deadline <= now
      void $
        execute
          "UPDATE browser_workspaces SET runtime_id=NULL,owner_turn_id=NULL,generation=generation+1,epoch=epoch+1,state=?,checkpoint=?,\
          \ checkpoint_at=CASE WHEN ? THEN NULL ELSE checkpoint_at END,profile_id=?,profile_version=?,revision=? WHERE task_id=? AND generation=? AND epoch=?"
          ( workspaceStateText state,
            if wipe then Nothing else space.checkpoint,
            wipe,
            if revised then Nothing else space.profile,
            if revised then Nothing else space.profileVersion,
            work.revision,
            identifier,
            generation,
            space.epoch
          )
    _ -> pure ()

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
resetBrowserWorkspace identifier = withTransaction $ do
  _ <- Task.lockTaskConversation identifier
  task <- Task.loadTask identifier
  case task of
    Nothing -> pure ()
    Just current ->
      void $
        execute
          "UPDATE browser_workspaces SET state='cold',generation=generation+1,epoch=epoch+1,revision=?,runtime_id=NULL,owner_turn_id=NULL,checkpoint=NULL,checkpoint_at=NULL,profile_id=NULL,profile_version=NULL WHERE task_id=?"
          (current.revision, identifier)

-- | Called in the profile mutation transaction after the conversation lock.
revokeProfileWorkspaces :: (WithConnection :> es, IOE :> es) => Int64 -> Eff es ()
revokeProfileWorkspaces identifier =
  void $
    execute
      "UPDATE browser_workspaces SET state='revoked',epoch=epoch+1,checkpoint=NULL,checkpoint_at=NULL WHERE profile_id=?"
      (Only identifier)
