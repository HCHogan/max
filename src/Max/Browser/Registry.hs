-- |
-- Browser registry: one camoufox-MCP /host container/ per 'GroupId', with an
-- isolated MCP client and browse session per task workspace or foreground turn.  Containers
-- are created lazily and reused across turns, then torn down on @!clear --all@
-- or bot exit.  Mirrors
-- "Max.Sandbox.Registry"; we reuse its @docker@ helpers for teardown
-- and boot-time reaping of the @max-br-@ namespace.
--
-- A 'BrowserScope' names one physical workspace generation or foreground turn.  Stateful operations are serialized only
-- inside that scope; sibling fork children get distinct scopes, MCP clients and
-- browse sessions, so they can navigate concurrently without changing each
-- other's page.  Docker creation is serialized per group, never globally.
module Max.Browser.Registry
  ( BrowserScope,
    browserScopeForTurn,
    browserScopeForDispatch,
    browserScopeForTask,
    BrowserRegistry,
    newBrowserRegistry,
    newBrowserRegistryWithHost,
    configureBrowserRegistry,
    browserRuntimeId,
    browserVault,
    browserRetention,
    withBrowserWorkspace,
    tryWithBrowserWorkspace,
    bindBrowserLease,
    renewBrowserLease,
    prepareBrowserRestore,
    takeBrowserRestore,
    liveTaskBrowsers,
    withBrowserSession,
    reapStaleBrowsers,
    callBrowserTool,
    getCamoSession,
    setCamoSession,
    releaseBrowserScope,
    stopBrowserScope,
    destroyBrowsersForGroup,
    destroyAllBrowsers,
    browserNamePrefix,
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM
import Control.Exception (bracket_, mask, mask_, onException)
import Control.Monad (void)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Bifunctor (first)
import Data.Foldable (for_)
import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime, getCurrentTime)
import Max.Browser.Docker
  ( browserHostPort,
    containerPort,
    defaultBrowserImage,
    runRunBrowser,
  )
import Max.Browser.Error
  ( BrowserError,
    browserCallFailed,
    browserErrorFromMcp,
  )
import Max.Browser.Lock (LockMap, newLockMap, tryWithKeyLock, withKeyLock)
import Max.Browser.Vault (BrowserVault, newBrowserVault)
import Max.HttpRuntime (HttpRuntime)
import Max.MCP.Client
  ( McpClient,
    McpErrorKind (McpSessionError),
    mcpCallTool,
    mcpErrorKind,
    mcpInitialize,
    mcpTerminate,
    newMcpClient,
    renderMcpError,
  )
import Max.Platform.Types (CanonicalMessageId)
import Max.Resource (acquireRegistered, releaseRegistered)
import Max.Sandbox.Docker (listContainersByPrefix, runRm)
import Max.Turn.Types (AgentTurnId)
import OneBot.Types (GroupId (..))
import System.Timeout (timeout)

browserNamePrefix :: Text
browserNamePrefix = "max-br-"

data BrowserEntry = BrowserEntry
  { beGroup :: !GroupId,
    beContainer :: !Text,
    beEndpoint :: !String,
    beHostHeader :: !String,
    beCreatedAt :: !UTCTime
  }

-- | Task generations and foreground turns are distinct browser owners.
data BrowserScope
  = BrowserTurnScope !GroupId !AgentTurnId
  | BrowserDispatchScope !GroupId !CanonicalMessageId
  | BrowserTaskScope !GroupId !Int64 !Int64
  deriving stock (Show, Eq, Ord)

browserScopeForTurn :: GroupId -> AgentTurnId -> BrowserScope
browserScopeForTurn = BrowserTurnScope

browserScopeForDispatch :: GroupId -> CanonicalMessageId -> BrowserScope
browserScopeForDispatch = BrowserDispatchScope

browserScopeForTask :: GroupId -> Int64 -> Int64 -> BrowserScope
browserScopeForTask = BrowserTaskScope

browserScopeGroup :: BrowserScope -> GroupId
browserScopeGroup = \case
  BrowserTurnScope gid _ -> gid
  BrowserDispatchScope gid _ -> gid
  BrowserTaskScope gid _ _ -> gid

data BrowserInstance = BrowserInstance
  { biClient :: McpClient,
    biHostCreatedAt :: !UTCTime
  }

data BrowserRegistry = BrowserRegistry
  { brHttp :: !HttpRuntime,
    -- | Container creation locks are per conversation.  Two unrelated groups,
    -- and the workspace-scoped MCP instances inside one ready container, can start
    -- concurrently.
    brStartLocks :: !(TVar (Map GroupId (TMVar ()))),
    brEntries :: !(TVar (Map GroupId BrowserEntry)),
    -- | One independent MCP transport session per physical workspace.
    brInstances :: !(TVar (Map BrowserScope BrowserInstance)),
    -- | The scope's live camoufox browse-session id, if a page is open.
    brCamoSessions :: !(TVar (Map BrowserScope Text)),
    -- | Reference-counted operation locks include holders and waiting callers.
    brSessionLocks :: !(LockMap BrowserScope),
    brWorkspaceLocks :: !(LockMap Int64),
    brLeases :: !(TVar (Map BrowserScope Value)),
    brRestores :: !(TVar (Map BrowserScope Value)),
    brRuntimeId :: !Text,
    brVault :: !BrowserVault,
    brIdleSeconds :: !Int,
    brGraceSeconds :: !Int
  }

newBrowserRegistry :: HttpRuntime -> IO BrowserRegistry
newBrowserRegistry runtime = do
  vault <- newBrowserVault
  started <- getCurrentTime
  BrowserRegistry runtime
    <$> newTVarIO Map.empty
    <*> newTVarIO Map.empty
    <*> newTVarIO Map.empty
    <*> newTVarIO Map.empty
    <*> newLockMap
    <*> newLockMap
    <*> newTVarIO Map.empty
    <*> newTVarIO Map.empty
    <*> pure (T.pack (show started))
    <*> pure vault
    <*> pure 1800
    <*> pure 300

configureBrowserRegistry :: BrowserVault -> Int -> Int -> BrowserRegistry -> BrowserRegistry
configureBrowserRegistry vault idle grace registry = registry {brVault = vault, brIdleSeconds = idle, brGraceSeconds = grace}

newBrowserRegistryWithHost :: HttpRuntime -> GroupId -> String -> String -> IO BrowserRegistry
newBrowserRegistryWithHost runtime group endpoint hostHeader = do
  registry <- newBrowserRegistry runtime
  created <- getCurrentTime
  let entry = BrowserEntry group "external-browser-host" endpoint hostHeader created
  atomically $ modifyTVar' registry.brEntries (Map.insert group entry)
  pure registry

browserRuntimeId :: BrowserRegistry -> Text
browserRuntimeId = (.brRuntimeId)

browserVault :: BrowserRegistry -> BrowserVault
browserVault = (.brVault)

browserRetention :: BrowserRegistry -> (Int, Int)
browserRetention registry = (registry.brIdleSeconds, registry.brGraceSeconds)

withBrowserWorkspace :: BrowserRegistry -> Int64 -> IO value -> IO value
withBrowserWorkspace registry = withKeyLock registry.brWorkspaceLocks

tryWithBrowserWorkspace :: BrowserRegistry -> Int64 -> IO value -> IO (Maybe value)
tryWithBrowserWorkspace registry = tryWithKeyLock registry.brWorkspaceLocks

bindBrowserLease :: BrowserRegistry -> BrowserScope -> Int64 -> UTCTime -> IO (Either BrowserError Value)
bindBrowserLease registry scope epoch untilTime = do
  let lease = object ["epoch" .= epoch, "until" .= untilTime]
  result <- callBrowserTool registry scope "max_workspace_bind" lease
  case result of
    Right _ -> atomically $ modifyTVar' registry.brLeases (Map.insert scope lease)
    Left _ -> pure ()
  pure result

renewBrowserLease :: BrowserRegistry -> BrowserScope -> Int64 -> UTCTime -> IO ()
renewBrowserLease registry scope epoch untilTime = do
  instances <- readTVarIO registry.brInstances
  leases <- readTVarIO registry.brLeases
  case (Map.lookup scope instances, Map.lookup scope leases) of
    (Just owned, Just _) -> void $ timeout 5_000_000 $ mcpCallTool owned.biClient "max_workspace_renew" (object ["epoch" .= epoch, "until" .= untilTime])
    _ -> pure ()

prepareBrowserRestore :: BrowserRegistry -> BrowserScope -> Value -> IO ()
prepareBrowserRestore registry scope value = atomically $ modifyTVar' registry.brRestores (Map.insert scope value)

takeBrowserRestore :: BrowserRegistry -> BrowserScope -> IO (Maybe Value)
takeBrowserRestore registry scope = atomically $ do
  restores <- readTVar registry.brRestores
  modifyTVar' registry.brRestores (Map.delete scope)
  pure (Map.lookup scope restores)

liveTaskBrowsers :: BrowserRegistry -> IO [(GroupId, Int64, Int64)]
liveTaskBrowsers registry = do
  instances <- readTVarIO registry.brInstances
  pure [(group, task, generation) | BrowserTaskScope group task generation <- Map.keys instances]

-- | Serialize stateful camoufox operations for one turn.  Different turns,
-- including sibling fork children in the same conversation, never share this
-- lock and continue to run concurrently.
withBrowserSession :: BrowserRegistry -> BrowserScope -> IO a -> IO a
withBrowserSession reg = withKeyLock reg.brSessionLocks

lockFor :: (Ord key) => TVar (Map key (TMVar ())) -> key -> IO (TMVar ())
lockFor ref key = atomically $ do
  locks <- readTVar ref
  case Map.lookup key locks of
    Just existing -> pure existing
    Nothing -> do
      created <- newTMVar ()
      writeTVar ref (Map.insert key created locks)
      pure created

-- | The turn's current camoufox browse-session id, if any.
getCamoSession :: BrowserRegistry -> BrowserScope -> IO (Maybe Text)
getCamoSession reg scope = Map.lookup scope <$> readTVarIO reg.brCamoSessions

-- | Record ('Just') or forget ('Nothing') the workspace's browse-session id.
setCamoSession :: BrowserRegistry -> BrowserScope -> Maybe Text -> IO ()
setCamoSession reg scope msid =
  atomically . modifyTVar' reg.brCamoSessions $
    maybe (Map.delete scope) (Map.insert scope) msid

-- | Reap leftover @max-br-@ containers from a previous unclean exit.
-- Run once at startup before any browser is created.
reapStaleBrowsers :: IO ()
reapStaleBrowsers = do
  cs <- listContainersByPrefix browserNamePrefix
  for_ cs runRm

--------------------------------------------------------------------------------
-- Lazy ensure.

-- | Get the group's browser, creating the container if needed.
ensureBrowserForGroup :: BrowserRegistry -> GroupId -> IO (Either Text BrowserEntry)
ensureBrowserForGroup reg gid = do
  startLock <- lockFor reg.brStartLocks gid
  bracket_
    (atomically $ takeTMVar startLock)
    (atomically $ putTMVar startLock ())
    $ do
      entries <- readTVarIO reg.brEntries
      case Map.lookup gid entries of
        Just entry -> pure (Right entry)
        Nothing -> createEntry reg gid

createEntry :: BrowserRegistry -> GroupId -> IO (Either Text BrowserEntry)
createEntry reg gid = do
  now <- getCurrentTime
  let GroupId raw = gid
      name = browserNamePrefix <> T.pack (show raw)
      prepare = do
        runRes <- runRunBrowser name defaultBrowserImage
        case runRes of
          Left err -> pure (Left err)
          Right _cid -> do
            portRes <- browserHostPort name
            case portRes of
              Left err -> pure (Left err)
              Right port -> do
                let endpoint = "http://127.0.0.1:" <> show port <> "/mcp"
                    -- supergateway does no Host validation; send the
                    -- container-internal bind anyway so a future server
                    -- with a rebinding guard works.
                    hostHeader = "localhost:" <> show containerPort
                pure . Right $
                  BrowserEntry
                    { beGroup = gid,
                      beContainer = name,
                      beEndpoint = endpoint,
                      beHostHeader = hostHeader,
                      beCreatedAt = now
                    }
      register entry = atomically $ modifyTVar' reg.brEntries (Map.insert gid entry)
  acquireRegistered prepare (runRm name) register

-- | Get the workspace's isolated MCP client, creating and initializing it if needed.
-- The scope lock held by every tool sequence also serializes this transition,
-- so there can be only one client per scope without a second creation lock.
ensureBrowserInstance :: BrowserRegistry -> BrowserScope -> IO (Either Text BrowserInstance)
ensureBrowserInstance reg scope = do
  instances <- readTVarIO reg.brInstances
  case Map.lookup scope instances of
    Just instance' -> pure (Right instance')
    Nothing -> do
      ensureBrowserForGroup reg (browserScopeGroup scope) >>= \case
        Left err -> pure (Left err)
        Right entry -> do
          client <- newMcpClient reg.brHttp entry.beEndpoint entry.beHostHeader
          let instance' = BrowserInstance client entry.beCreatedAt
              rollback = dropFailedBrowserInstance reg scope entry instance'
          mask $ \restore -> do
            -- Publish the initializing instance first.  Host retirement can
            -- now see every sibling that still depends on this container,
            -- including one whose MCP child has not finished starting yet.
            atomically $ modifyTVar' reg.brInstances (Map.insert scope instance')
            restore (waitReady client) `onException` rollback >>= \case
              Left err -> Left err <$ rollback
              Right () -> pure (Right instance')

dropFailedBrowserInstance :: BrowserRegistry -> BrowserScope -> BrowserEntry -> BrowserInstance -> IO ()
dropFailedBrowserInstance reg scope entry instance' = mask_ $ do
  void (timeout 5_000_000 (mcpTerminate instance'.biClient))
  atomically $ modifyTVar' reg.brInstances (deleteOwnedInstance scope entry.beCreatedAt)
  retireBrowserHostIfUnused reg entry

deleteOwnedInstance :: BrowserScope -> UTCTime -> Map BrowserScope BrowserInstance -> Map BrowserScope BrowserInstance
deleteOwnedInstance scope generation instances =
  case Map.lookup scope instances of
    Just instance' | instance'.biHostCreatedAt == generation -> Map.delete scope instances
    _ -> instances

-- | Replace an unhealthy host only after its last dependent scope has gone.
-- The group start lock orders this check against both new instance lookup and
-- @!clear --all@; the creation timestamp prevents a late old failure from
-- retiring a replacement container that reused the stable Docker name.
retireBrowserHostIfUnused :: BrowserRegistry -> BrowserEntry -> IO ()
retireBrowserHostIfUnused reg failedEntry = do
  startLock <- lockFor reg.brStartLocks failedEntry.beGroup
  bracket_
    (atomically $ takeTMVar startLock)
    (atomically $ putTMVar startLock ())
    $ do
      entries <- readTVarIO reg.brEntries
      instances <- readTVarIO reg.brInstances
      let isCurrent entry = entry.beCreatedAt == failedEntry.beCreatedAt
          stillUsed (scope, instance') =
            browserScopeGroup scope == failedEntry.beGroup
              && instance'.biHostCreatedAt == failedEntry.beCreatedAt
      case Map.lookup failedEntry.beGroup entries of
        Just current
          | isCurrent current && not (any stillUsed (Map.toList instances)) ->
              releaseBrowser reg current
        _ -> pure ()

-- | Poll @initialize@ until the MCP server answers or we give up.
-- supergateway spawns a camoufox-mcp child per @initialize@, so the
-- first success also covers the child's node startup.
waitReady :: McpClient -> IO (Either Text ())
waitReady client = go 0
  where
    stepMs = 1000
    maxMs = 90_000
    go elapsed
      | elapsed >= maxMs = pure (Left "browser MCP did not become ready within 90s")
      | otherwise = do
          r <- mcpInitialize client
          case r of
            Right () -> pure (Right ())
            Left _ -> threadDelay (stepMs * 1000) >> go (elapsed + stepMs)

--------------------------------------------------------------------------------
-- Tool call.

-- | Ensure the isolated browser instance exists. Transport loss may initialize
-- a fresh client, but never retries the original operation.
callBrowserTool :: BrowserRegistry -> BrowserScope -> Text -> Value -> IO (Either BrowserError Value)
callBrowserTool reg scope toolName args = do
  eInstance <- ensureBrowserInstance reg scope
  case eInstance of
    Left err -> pure (Left (browserCallFailed ("browser unavailable: " <> err)))
    Right instance' -> do
      lease <- Map.lookup scope <$> readTVarIO reg.brLeases
      let arguments = case (args, lease) of
            (Object fields, Just value) | toolName /= "max_workspace_bind" -> Object (KeyMap.insert "_maxLease" value fields)
            _ -> args
      r <- mcpCallTool instance'.biClient toolName arguments
      case r of
        Left err | err.mcpErrorKind == McpSessionError -> do
          setCamoSession reg scope Nothing
          reinit <- mcpInitialize instance'.biClient
          case reinit of
            Right () -> pure (Left (browserCallFailed "browser transport restarted; previous operation was not replayed"))
            Left _ -> do
              entries <- readTVarIO reg.brEntries
              case Map.lookup (browserScopeGroup scope) entries of
                Just entry
                  | entry.beCreatedAt == instance'.biHostCreatedAt ->
                      dropFailedBrowserInstance reg scope entry instance'
                _ -> do
                  void (timeout 5_000_000 (mcpTerminate instance'.biClient))
                  atomically $ modifyTVar' reg.brInstances (deleteOwnedInstance scope instance'.biHostCreatedAt)
              pure . Left . browserCallFailed $
                "browser instance lost; reinitialized without replay (was: "
                  <> renderMcpError err
                  <> ")"
        _ -> pure (first browserErrorFromMcp r)

--------------------------------------------------------------------------------
-- Teardown.

-- | Destroy the group's browser container (if any).  Returns how many
-- were removed (0 or 1).  Used by @!clear --all@.
destroyBrowsersForGroup :: BrowserRegistry -> GroupId -> IO Int
destroyBrowsersForGroup reg gid = do
  startLock <- lockFor reg.brStartLocks gid
  bracket_
    (atomically $ takeTMVar startLock)
    (atomically $ putTMVar startLock ())
    $ do
      entries <- filter ((== gid) . (.beGroup)) . Map.elems <$> readTVarIO reg.brEntries
      for_ entries (releaseBrowser reg)
      atomically $ do
        modifyTVar' reg.brInstances (Map.filterWithKey (\scope _ -> browserScopeGroup scope /= gid))
        modifyTVar' reg.brCamoSessions (Map.filterWithKey (\scope _ -> browserScopeGroup scope /= gid))
        modifyTVar' reg.brLeases (Map.filterWithKey (\scope _ -> browserScopeGroup scope /= gid))
        modifyTVar' reg.brRestores (Map.filterWithKey (\scope _ -> browserScopeGroup scope /= gid))
      pure (length entries)

-- | Close and forget the browser owned by one finished turn.  Cleanup is
-- bounded: a wedged browser must not hold the turn finalizer or shutdown drain
-- hostage.  The group host container remains available to sibling turns.
releaseBrowserScope :: BrowserRegistry -> BrowserScope -> IO ()
releaseBrowserScope reg scope = do
  withBrowserSession reg scope $ do
    getCamoSession reg scope >>= \case
      Nothing -> pure ()
      Just sid -> do
        setCamoSession reg scope Nothing
        _ <- timeout 5_000_000 (callBrowserTool reg scope "browse_session_close" (object ["sessionId" .= sid]))
        pure ()
    instance' <- Map.lookup scope <$> readTVarIO reg.brInstances
    for_ instance' $ \owned -> void (timeout 5_000_000 (mcpTerminate owned.biClient))
    atomically $ modifyTVar' reg.brInstances (Map.delete scope)
  atomically $ do
    modifyTVar' reg.brLeases (Map.delete scope)
    modifyTVar' reg.brRestores (Map.delete scope)

stopBrowserScope :: BrowserRegistry -> BrowserScope -> IO Bool
stopBrowserScope registry scope = withBrowserSession registry scope $ do
  instance' <- Map.lookup scope <$> readTVarIO registry.brInstances
  case instance' of
    Nothing -> pure True
    Just owned -> do
      result <- timeout 20_000_000 (mcpCallTool owned.biClient "max_workspace_revoke" (object []))
      case result of
        Just (Right _) -> do
          void (timeout 5_000_000 (mcpTerminate owned.biClient))
          atomically $ do
            modifyTVar' registry.brInstances (Map.delete scope)
            modifyTVar' registry.brCamoSessions (Map.delete scope)
            modifyTVar' registry.brLeases (Map.delete scope)
            modifyTVar' registry.brRestores (Map.delete scope)
          pure True
        _ -> pure False

-- | Tear down every browser container.  Used by the top-level bracket
-- in @main@ on bot exit.
destroyAllBrowsers :: BrowserRegistry -> IO ()
destroyAllBrowsers reg = do
  entries <- Map.elems <$> readTVarIO reg.brEntries
  for_ entries (releaseBrowser reg)
  atomically $ do
    writeTVar reg.brInstances Map.empty
    writeTVar reg.brCamoSessions Map.empty
    writeTVar reg.brLeases Map.empty
    writeTVar reg.brRestores Map.empty
    writeTVar reg.brStartLocks Map.empty

releaseBrowser :: BrowserRegistry -> BrowserEntry -> IO ()
releaseBrowser reg entry =
  releaseRegistered
    (runRm entry.beContainer)
    (atomically $ modifyTVar' reg.brEntries (Map.delete entry.beGroup))
