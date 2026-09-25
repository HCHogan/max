module Max.Browser.Runtime
  ( managedBrowserTools,
    browserMaintenance,
    releaseBrowserTurn,
    resetTaskBrowser,
    ownedJobBrowser,
    stopJobBrowser,
    revokeProfileBrowsers,
    exportJobBrowser,
    profileIdentity,
    checkpointPayload,
  )
where

import Control.Monad (forM_, void, when)
import Data.Aeson
import Data.Aeson.Types (parseMaybe)
import Data.Int (Int64)
import Data.Maybe (isJust, isNothing)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (diffUTCTime, getCurrentTime)
import Database.PostgreSQL.Simple (Only (..))
import Effectful
import Effectful.Exception (onException)
import Effectful.PostgreSQL (WithConnection, query)
import Max.Browser.Error (renderBrowserError)
import Max.Browser.Registry
import Max.Browser.Vault (openBrowserState)
import Max.Effects.Tools (Tool (..), ToolRunner (..), toolRun)
import Max.Execution.Types (ExecutionStep (..), StepReservation (..))
import Max.Jobs qualified as Jobs
import Max.Platform.Types (PrincipalId)
import Max.Task.Types (JobRun (..), JobSpec (..), JobView (..))
import Max.ToolContext
import Max.Turn.Types (AgentTurnId, AgentTurnRef (..), turnOutputAgentTurn)
import OneBot.Types (GroupId)

profileIdentity :: Int64 -> Text
profileIdentity identifier = "browser/profile/" <> T.pack (show identifier)

checkpointPayload :: Value -> Maybe Value
checkpointPayload = parseMaybe (withObject "MCP checkpoint" (.: "structuredContent"))

managedBrowserTools :: (WithConnection :> es, IOE :> es) => Jobs.Jobs -> ToolContext -> BrowserRegistry -> (BrowserScope -> [Tool es]) -> [Tool es]
managedBrowserTools jobs context registry build = map wrap (build fallback)
  where
    group = toolGroupId context
    owner = (.atrTurnId) . turnOutputAgentTurn <$> toolTurnOutputContext context
    fallback = maybe (browserScopeForDispatch group (toolCanonicalId context)) (browserScopeForTurn group) owner
    wrap original =
      original
        { toolRunner = LegacyRunner $ \arguments -> case owner of
            Nothing -> toolRun original arguments
            Just turn -> do
              job <- liftIO (Jobs.jobForTurn jobs turn)
              case job of
                Nothing -> do
                  allowed <- liftIO (Jobs.authorizeJobStep jobs turn (ExecutionWork CheckOnly))
                  if allowed then toolRun original arguments else pure (Left "browser turn ended")
                Just task -> withSeqEffToIO $ \unlift -> liftIO $ withBrowserWorkspace registry task.run.jobId $ unlift $ do
                  allowed <- liftIO (Jobs.authorizeJobStep jobs turn (ExecutionWork CheckOnly))
                  current <- liftIO (Jobs.jobForTurn jobs turn)
                  if not allowed || maybe True (not . (.browserAllowed)) current
                    then pure (Left "browser job ended or browser access was revoked")
                    else do
                      prepared <- liftIO (prepareWorkspace registry task)
                      case prepared of
                        Left detail -> pure (Left detail)
                        Right workspace | workspace.jbUncertain -> pure (Left "browser outcome is uncertain; inspect the site and ask the owner to !browser reset before further actions")
                        Right workspace -> do
                          profile <- loadProfile registry workspace.jbProfile
                          case profile of
                            Left detail -> pure (Left detail)
                            Right saved -> do
                              session <- liftIO (getCamoSession registry workspace.jbScope)
                              let cold = isNothing session
                                  action = parseMaybe (withObject "browser arguments" (.: "action")) arguments
                                  canOpen = original.toolName == "view_zhihu" || action == Just ("open" :: Text)
                              if cold && not canOpen
                                then pure (Left "browser session closed; open the page and obtain fresh selectors. Never replay an uncertain action")
                                else do
                                  bound <- liftIO (ensureJobBrowserLease registry workspace.jbScope task.spec.deadline)
                                  case bound of
                                    Left _ -> pure (Left "browser workspace binding failed; no action was replayed")
                                    Right _ -> do
                                      when cold $ forM_ saved (liftIO . prepareBrowserRestore registry workspace.jbScope)
                                      let uncertain = liftIO (putJobBrowser registry task.run.jobId (workspace {jbUncertain = True}))
                                          run = case [tool | tool <- build workspace.jbScope, tool.toolName == original.toolName] of
                                            [tool] -> toolRun tool arguments
                                            _ -> pure (Left "browser tool unavailable")
                                      result <- run `onException` uncertain
                                      now <- liftIO getCurrentTime
                                      let readOnly = original.toolName == "view_zhihu" || action `elem` map Just ["open", "snapshot", "scroll", "wait_for", "read", "find", "links", "forms", "screenshot", "collect"]
                                          ambiguous = not readOnly && either (const True) (const False) result
                                      liftIO (putJobBrowser registry task.run.jobId (workspace {jbLastUsed = now, jbUncertain = ambiguous}))
                                      pure result
        }

-- Profile storage is explicit user data. No task state is checkpointed here.
loadProfile :: (WithConnection :> es, IOE :> es) => BrowserRegistry -> Maybe (Int64, Int64) -> Eff es (Either Text (Maybe Value))
loadProfile _ Nothing = pure (Right Nothing)
loadProfile registry (Just (profile, version)) = do
  rows <- query "SELECT checkpoint FROM browser_profiles WHERE profile_id=? AND version=? AND NOT revoked AND checkpoint IS NOT NULL" (profile, version)
  pure $ case rows of
    [Only encrypted] -> Just <$> openBrowserState (browserVault registry) (profileIdentity profile) encrypted
    _ -> Left "browser profile was changed or revoked; owner must explicitly attach a current profile"

prepareWorkspace :: BrowserRegistry -> JobView -> IO (Either Text JobBrowser)
prepareWorkspace registry job = do
  previous <- jobBrowser registry job.run.jobId
  case previous of
    Just current | current.jbRun == job.run -> pure (Right current)
    _ -> do
      stopped <- maybe (pure True) (stopBrowserScope registry . (.jbScope)) previous
      if not stopped
        then pure (Left "old browser did not confirm closure")
        else do
          now <- getCurrentTime
          let generation = maybe 1 ((+ 1) . (.jbGeneration)) previous
              created = JobBrowser job.run (browserScopeForTask job.spec.group job.run.jobId generation) generation job.spec.browserProfile False now Nothing
          putJobBrowser registry job.run.jobId created
          pure (Right created)

ownedJobBrowser :: (IOE :> es) => Jobs.Jobs -> BrowserRegistry -> GroupId -> PrincipalId -> Int64 -> (JobView -> Eff es (Either Text value)) -> Eff es (Either Text value)
ownedJobBrowser jobs registry group actor identifier action = withSeqEffToIO $ \unlift -> liftIO $ withBrowserWorkspace registry identifier $ unlift $ do
  job <- liftIO (Jobs.lookupJob jobs group identifier)
  case job of
    Just task | task.spec.principal == actor -> action task
    _ -> pure (Left "task not found or browser owner permission required")

stopJobBrowser :: BrowserRegistry -> Int64 -> IO Bool
stopJobBrowser registry identifier = do
  workspace <- jobBrowser registry identifier
  maybe (pure True) (stopBrowserScope registry . (.jbScope)) workspace

resetTaskBrowser :: (IOE :> es) => Jobs.Jobs -> BrowserRegistry -> GroupId -> PrincipalId -> Int64 -> Maybe (Int64, Int64) -> Eff es (Either Text Value)
resetTaskBrowser jobs registry group actor identifier profile = ownedJobBrowser jobs registry group actor identifier $ \job -> do
  stopped <- liftIO (stopJobBrowser registry identifier)
  if not stopped
    then pure (Left "old browser did not confirm closure; reset refused")
    else do
      liftIO (Jobs.setJobBrowserAccess jobs job.run True)
      previous <- liftIO (jobBrowser registry identifier)
      now <- liftIO getCurrentTime
      let generation = maybe 1 ((+ 1) . (.jbGeneration)) previous
      liftIO (putJobBrowser registry identifier (JobBrowser job.run (browserScopeForTask group identifier generation) generation profile False now Nothing))
      pure (Right (object ["reset" .= True, "agent" .= identifier]))

exportJobBrowser :: (IOE :> es) => BrowserRegistry -> Int64 -> Eff es (Either Text Value)
exportJobBrowser registry identifier = liftIO $ do
  workspace <- jobBrowser registry identifier
  case workspace of
    Just current | not current.jbUncertain -> do
      session <- getCamoSession registry current.jbScope
      case session of
        Nothing -> pure (Left "browser has no live session to save")
        Just sessionId -> do
          result <- callBrowserTool registry current.jbScope "max_workspace_checkpoint" (object ["sessionId" .= sessionId])
          pure $ case result of
            Left err -> Left (renderBrowserError err)
            Right value -> maybe (Left "invalid browser profile export") Right (checkpointPayload value)
    _ -> pure (Left "no safe live browser is available for this task")

revokeProfileBrowsers :: BrowserRegistry -> Int64 -> IO ()
revokeProfileBrowsers registry profile = do
  workspaces <- jobBrowsers registry
  forM_ workspaces $ \(identifier, _) -> withBrowserWorkspace registry identifier $ do
    current <- jobBrowser registry identifier
    forM_ current $ \workspace -> when (fmap fst workspace.jbProfile == Just profile) $ void (stopBrowserScope registry workspace.jbScope)

browserMaintenance :: (IOE :> es) => BrowserRegistry -> Eff es ()
browserMaintenance registry = liftIO $ do
  retryBrowserReleases registry
  now <- getCurrentTime
  let (idle, grace) = browserRetention registry
  workspaces <- jobBrowsers registry
  forM_ workspaces $ \(identifier, _) -> void $ tryWithBrowserWorkspace registry identifier $ do
    current <- jobBrowser registry identifier
    forM_ current $ \workspace -> do
      let expired = case workspace.jbFinished of
            Just finished -> diffUTCTime now finished >= fromIntegral grace
            Nothing -> diffUTCTime now workspace.jbLastUsed >= fromIntegral idle
      if expired
        then do
          stopped <- stopBrowserScope registry workspace.jbScope
          when (stopped && isJust workspace.jbFinished) (forgetJobBrowser registry identifier)
        else do
          session <- getCamoSession registry workspace.jbScope
          forM_ session $ \sessionId -> void (callBrowserTool registry workspace.jbScope "max_workspace_keepalive" (object ["sessionId" .= sessionId]))

releaseBrowserTurn :: (IOE :> es) => Jobs.Jobs -> BrowserRegistry -> GroupId -> AgentTurnId -> Eff es ()
releaseBrowserTurn jobs registry group turn = liftIO $ do
  job <- Jobs.jobForTurn jobs turn
  case job of
    Nothing -> releaseBrowserScope registry (browserScopeForTurn group turn)
    Just task -> withBrowserWorkspace registry task.run.jobId $ do
      workspace <- jobBrowser registry task.run.jobId
      forM_ workspace $ \current -> when (current.jbRun == task.run) $ do
        now <- getCurrentTime
        putJobBrowser registry task.run.jobId (current {jbFinished = Just now})
