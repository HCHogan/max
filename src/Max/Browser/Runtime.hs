module Max.Browser.Runtime (managedBrowserTools, browserMaintenance, releaseBrowserTurn, renewBrowserTurn, resetTaskBrowser, workspaceIdentity, profileIdentity, checkpointPayload) where

import Control.Monad (forM_, void, when)
import Data.Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (parseMaybe)
import Data.Either (fromRight)
import Data.Int (Int64)
import Data.Maybe (isNothing)
import Data.Text (Text)
import Data.Text qualified as T
import Database.PostgreSQL.Simple (Only (..))
import Effectful
import Effectful.Exception (onException)
import Effectful.PostgreSQL (WithConnection, execute, query)
import Max.Browser.Error (renderBrowserError)
import Max.Browser.Registry
import Max.Browser.Vault (openBrowserState, sealBrowserState)
import Max.DB.Browser
import Max.DB.Task (authorizeTaskStep)
import Max.Effects.Tools (Tool (..))
import Max.Platform.Types (PrincipalId)
import Max.ToolContext (ToolContext, toolCanonicalId, toolGroupId, toolTurnOutputContext)
import Max.Turn.Types (AgentTurnId, AgentTurnRef (..), turnOutputAgentTurn)
import OneBot.Types (GroupId)
import System.Timeout (timeout)

workspaceIdentity :: Int64 -> Text
workspaceIdentity identifier = "browser/task/" <> T.pack (show identifier)

profileIdentity :: Int64 -> Text
profileIdentity identifier = "browser/profile/" <> T.pack (show identifier)

checkpointPayload :: Value -> Maybe Value
checkpointPayload = parseMaybe (withObject "MCP checkpoint" (.: "structuredContent"))

managedBrowserTools :: (WithConnection :> es, IOE :> es) => ToolContext -> BrowserRegistry -> (BrowserScope -> [Tool es]) -> [Tool es]
managedBrowserTools context registry build = map wrap (build fallback)
  where
    group = toolGroupId context
    durable = (.atrTurnId) . turnOutputAgentTurn <$> toolTurnOutputContext context
    fallback = maybe (browserScopeForDispatch group (toolCanonicalId context)) (browserScopeForTurn group) durable
    wrap original =
      original
        { toolRun = \arguments -> case durable of
            Nothing -> original.toolRun arguments
            Just turn -> do
              identity <- taskBrowserIdentity turn group
              case identity of
                Nothing -> do
                  allowed <- authorizeTaskStep turn (Just original.toolName) False
                  if allowed then original.toolRun arguments else pure (Left "browser execution was fenced")
                Just identifier -> withSeqEffToIO $ \unlift ->
                  liftIO $ withBrowserWorkspace registry identifier $ unlift $ do
                    acquired <- acquireReady turn identifier
                    case acquired of
                      Left detail -> pure (Left detail)
                      Right workspace -> do
                        let scope = browserScopeForTask group identifier workspace.bwGeneration
                        session <- liftIO (getCamoSession registry scope)
                        let cold = workspace.bwState == "cold" || isNothing session
                        if cold && original.toolName `notElem` ["browser_navigate", "view_zhihu"]
                          then pure (Left "browser workspace is cold; call browser_navigate and obtain a fresh snapshot. DOM, JS state and previous selectors were not restored; never replay uncertain actions")
                          else case restoreWorkspace workspace of
                            Left detail -> pure (Left detail)
                            Right restored -> do
                              lease <- liftIO (bindBrowserLease registry scope workspace.bwEpoch workspace.bwLeaseUntil)
                              case lease of
                                Left _ -> pure (Left "browser lease binding failed; no action was replayed")
                                Right _ -> do
                                  when cold $ forM_ restored (liftIO . prepareBrowserRestore registry scope)
                                  allowed <- beginBrowserOperation turn workspace.bwEpoch
                                  if not allowed
                                    then pure (Left "browser execution was fenced before operation")
                                    else do
                                      let run = case [tool | tool <- build scope, tool.toolName == original.toolName] of
                                            [tool] -> tool.toolRun arguments
                                            _ -> pure (Left "browser tool unavailable")
                                          interrupted = void (finishBrowserOperation turn workspace.bwEpoch Nothing False)
                                      ( do
                                          result <- run
                                          saved <- saveCheckpoint registry scope identifier
                                          let readOnlyFailure = original.toolName `elem` ["browser_navigate", "browser_snapshot", "browser_scroll", "browser_wait_for", "view_zhihu"]
                                              healthy = (readOnlyFailure || either (const False) (const True) result) && either (const False) (const True) saved
                                          accepted <- finishBrowserOperation turn workspace.bwEpoch (fromRight Nothing saved) healthy
                                          if not accepted
                                            then pure (Left "browser execution was fenced after operation; its external outcome may already have occurred")
                                            else
                                              if not healthy
                                                then pure (Left "browser operation or checkpoint failed; outcome may be unknown. Do not repeat it; inspect the external site and use !browser reset task#N before continuing")
                                                else pure (fmap (addRecovery cold) result)
                                        )
                                        `onException` interrupted
        }
    addRecovery False value = value
    addRecovery True (Object fields) = Object (KeyMap.insert "browser_recovery" (String "cold workspace; only saved authentication storage restored, never DOM or JS. Use the new snapshot, not old selectors") fields)
    addRecovery True value = value
    restoreWorkspace workspace = case workspace.bwCheckpoint of
      Just saved -> Just <$> openBrowserState (browserVault registry) (workspaceIdentity workspace.bwTask) saved
      Nothing -> case (workspace.bwProfile, workspace.bwProfileCheckpoint) of
        (Just profile, Just saved) -> Just <$> openBrowserState (browserVault registry) (profileIdentity profile) saved
        _ -> Right Nothing
    acquireReady turn identifier = do
      acquired <- acquireBrowserWorkspace turn (browserRuntimeId registry)
      case acquired of
        Right workspace | workspace.bwState == "hot" -> do
          let scope = browserScopeForTask group identifier workspace.bwGeneration
          session <- liftIO (getCamoSession registry scope)
          if isNothing session
            then do
              stopped <- liftIO (stopBrowserScope registry scope)
              if not stopped
                then pure (Left "previous browser did not confirm closure; cold recovery refused")
                else do
                  retireBrowserWorkspace identifier workspace.bwGeneration
                  acquireBrowserWorkspace turn (browserRuntimeId registry)
            else pure acquired
        _ -> pure acquired

saveCheckpoint :: (IOE :> es) => BrowserRegistry -> BrowserScope -> Int64 -> Eff es (Either Text (Maybe Text))
saveCheckpoint registry scope identifier = liftIO $ do
  session <- getCamoSession registry scope
  case session of
    Nothing -> pure (Right Nothing)
    Just sessionId -> do
      result <- callBrowserTool registry scope "max_workspace_checkpoint" (object ["sessionId" .= sessionId])
      case result of
        Left detail -> pure (Left (renderBrowserError detail))
        Right value -> case checkpointPayload value of
          Nothing -> pure (Left "invalid browser checkpoint")
          Just payload -> Right . Just <$> sealBrowserState (browserVault registry) (workspaceIdentity identifier) payload

browserMaintenance :: (WithConnection :> es, IOE :> es) => BrowserRegistry -> Eff es ()
browserMaintenance registry = do
  liftIO (retryBrowserReleases registry)
  let (idle, grace) = browserRetention registry
  candidates <- browserGcCandidates idle grace
  forM_ candidates $ \(group, identifier, generation, _) -> withSeqEffToIO $ \unlift ->
    liftIO $ void $ tryWithBrowserWorkspace registry identifier $ unlift $ do
      current <- browserGcCandidates idle grace
      when (any (\(_, task, version, _) -> task == identifier && version == generation) current) $ do
        stopped <- liftIO (stopBrowserScope registry (browserScopeForTask group identifier generation))
        when stopped (retireBrowserWorkspace identifier generation)
  live <- liftIO (liveTaskBrowsers registry)
  forM_ live $ \(group, identifier, generation) -> withSeqEffToIO $ \unlift ->
    liftIO $ void $ tryWithBrowserWorkspace registry identifier $ unlift $ do
      rows <- browserWorkspace identifier
      let scope = browserScopeForTask group identifier generation
      case rows of
        [(current, _, state, Just runtime)]
          | current == generation && runtime == browserRuntimeId registry && state `elem` ["hot", "cold", "busy"] -> do
              session <- liftIO (getCamoSession registry scope)
              forM_ session $ \sessionId ->
                liftIO $
                  void $
                    callBrowserTool registry scope "max_workspace_keepalive" (object ["sessionId" .= sessionId])
        _ -> liftIO (void (stopBrowserScope registry scope))

resetTaskBrowser :: (WithConnection :> es, IOE :> es) => BrowserRegistry -> GroupId -> PrincipalId -> Int64 -> Eff es (Either Text Value)
resetTaskBrowser registry group actor identifier = withSeqEffToIO $ \unlift ->
  liftIO $ withBrowserWorkspace registry identifier $ unlift $ do
    allowed <- browserCommandOwner group actor identifier
    if not allowed
      then pure (Left "task not found or browser owner permission required")
      else do
        rows <- browserWorkspace identifier
        stopped <- case rows of
          [(generation, _, _, _)] -> liftIO (stopBrowserScope registry (browserScopeForTask group identifier generation))
          _ -> pure True
        if not stopped
          then pure (Left "old browser did not confirm closure; reset refused")
          else do
            resetBrowserWorkspace identifier
            pure (Right (object ["reset" .= True, "task" .= identifier]))

releaseBrowserTurn :: (WithConnection :> es, IOE :> es) => BrowserRegistry -> GroupId -> AgentTurnId -> Eff es ()
releaseBrowserTurn registry group turn = do
  identity <- taskBrowserIdentity turn group
  case identity of
    Nothing -> liftIO (releaseBrowserScope registry (browserScopeForTurn group turn))
    Just identifier -> withSeqEffToIO $ \unlift -> liftIO $ withBrowserWorkspace registry identifier $ unlift $ do
      rows <- query "SELECT generation FROM browser_workspaces WHERE task_id=? AND owner_turn_id=?" (identifier, turn)
      forM_ rows $ \(Only generation) -> do
        let scope = browserScopeForTask group identifier generation
        session <- liftIO (getCamoSession registry scope)
        forM_ session $ \_ -> liftIO $ void (timeout 5_000_000 (callBrowserTool registry scope "max_workspace_unbind" (object [])))
        void $ execute "UPDATE browser_workspaces SET owner_turn_id=NULL,epoch=epoch+1,state=CASE WHEN state='busy' THEN 'uncertain' ELSE state END WHERE task_id=? AND owner_turn_id=?" (identifier, turn)

renewBrowserTurn :: (WithConnection :> es, IOE :> es) => BrowserRegistry -> GroupId -> AgentTurnId -> Eff es ()
renewBrowserTurn registry group turn = do
  allowed <- authorizeTaskStep turn (Just "browser_navigate") False
  when allowed $ do
    rows <- query "SELECT space.task_id,space.generation,space.epoch,attempt.lease_until FROM browser_workspaces space JOIN task_attempts attempt ON attempt.turn_id=space.owner_turn_id WHERE space.owner_turn_id=? AND space.runtime_id=? AND space.state IN ('cold','hot','busy')" (turn, browserRuntimeId registry)
    forM_ rows $ \(identifier, generation, epoch, untilTime) ->
      liftIO $
        renewBrowserLease registry (browserScopeForTask group identifier generation) epoch untilTime
