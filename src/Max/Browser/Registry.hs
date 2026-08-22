-- |
-- Browser registry: one camoufox-MCP /host container/ per 'GroupId', with an
-- isolated MCP client and camoufox browse session per agent turn.  Containers
-- are created lazily and reused across turns, then torn down on @!clear --all@
-- or bot exit.  Mirrors
-- "Max.Sandbox.Registry"; we reuse its @docker@ helpers for teardown
-- and boot-time reaping of the @max-br-@ namespace.
--
-- A 'BrowserScope' names one turn.  Stateful operations are serialized only
-- inside that scope; sibling fork children get distinct scopes, MCP clients and
-- browse sessions, so they can navigate concurrently without changing each
-- other's page.  Docker creation is serialized per group, never globally.
module Max.Browser.Registry
  ( BrowserScope,
    browserScopeForTurn,
    browserScopeForDispatch,
    BrowserRegistry,
    brProxy,
    newBrowserRegistry,
    withBrowserSession,
    reapStaleBrowsers,
    callBrowserTool,
    getCamoSession,
    setCamoSession,
    releaseBrowserScope,
    destroyBrowsersForGroup,
    destroyAllBrowsers,
    browserNamePrefix,
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM
import Control.Exception (bracket_, mask, mask_, onException)
import Control.Monad (void)
import Data.Aeson (Value, object, (.=))
import Data.Bifunctor (first)
import Data.Foldable (for_)
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

-- | One stateful browser owner.  A durable turn is the normal owner; the
-- dispatch fallback exists only for tool contexts that predate durable output
-- provenance.  Both constructors include the conversation so @!clear --all@
-- can still revoke every browser belonging to it.
data BrowserScope
  = BrowserTurnScope !GroupId !AgentTurnId
  | BrowserDispatchScope !GroupId !CanonicalMessageId
  deriving stock (Show, Eq, Ord)

browserScopeForTurn :: GroupId -> AgentTurnId -> BrowserScope
browserScopeForTurn = BrowserTurnScope

browserScopeForDispatch :: GroupId -> CanonicalMessageId -> BrowserScope
browserScopeForDispatch = BrowserDispatchScope

browserScopeGroup :: BrowserScope -> GroupId
browserScopeGroup = \case
  BrowserTurnScope gid _ -> gid
  BrowserDispatchScope gid _ -> gid

data BrowserInstance = BrowserInstance
  { biClient :: McpClient,
    biHostCreatedAt :: !UTCTime
  }

data BrowserRegistry = BrowserRegistry
  { brHttp :: !HttpRuntime,
    -- | Container creation locks are per conversation.  Two unrelated groups,
    -- and the turn-scoped MCP instances inside one ready container, can start
    -- concurrently.
    brStartLocks :: !(TVar (Map GroupId (TMVar ()))),
    brEntries :: !(TVar (Map GroupId BrowserEntry)),
    -- | One independent MCP transport session per turn/subagent.
    brInstances :: !(TVar (Map BrowserScope BrowserInstance)),
    -- | The scope's live camoufox browse-session id, if a page is open.
    brCamoSessions :: !(TVar (Map BrowserScope Text)),
    -- | One operation lock per turn.  It covers the whole
    -- read/start/use/update sequence in the tool layer, including the period
    -- before a camoufox session id exists.  A scope finalizer removes its lock
    -- only after the agent has joined every tool call for that turn.
    brSessionLocks :: !(TVar (Map BrowserScope (TMVar ()))),
    -- | Proxy URL every browse session routes through (config
    -- @browser.proxy@); 'Nothing' = direct.  "Max.Tools.Browser"
    -- passes it to @browse_session_start@.
    brProxy :: !(Maybe Text)
  }

newBrowserRegistry :: HttpRuntime -> Maybe Text -> IO BrowserRegistry
newBrowserRegistry runtime proxy =
  BrowserRegistry runtime
    <$> newTVarIO Map.empty
    <*> newTVarIO Map.empty
    <*> newTVarIO Map.empty
    <*> newTVarIO Map.empty
    <*> newTVarIO Map.empty
    <*> pure proxy

-- | Serialize stateful camoufox operations for one turn.  Different turns,
-- including sibling fork children in the same conversation, never share this
-- lock and continue to run concurrently.
withBrowserSession :: BrowserRegistry -> BrowserScope -> IO a -> IO a
withBrowserSession reg scope action = do
  lock <- lockFor reg.brSessionLocks scope
  bracket_
    (atomically $ takeTMVar lock)
    (atomically $ putTMVar lock ())
    action

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

-- | Record ('Just') or forget ('Nothing') the turn's browse-session id.
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

-- | Get the turn's isolated MCP client, creating and initializing it if needed.
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

-- | Ensure this turn's isolated browser instance is up, then invoke one MCP
-- tool on it.
--
-- Resilience: the MCP session can be lost out from under us (server
-- recycles it, the gateway restarts, memory pressure).  On that we
-- re-run the @initialize@ handshake once and retry; if even that fails
-- the container is unhealthy, so we tear it down and report — the next
-- call rebuilds a fresh one.  Re-initializing makes supergateway spawn
-- a *fresh* camoufox-mcp child, so this scope's browse session died with the old
-- one — forget it without disturbing sibling turns.
callBrowserTool :: BrowserRegistry -> BrowserScope -> Text -> Value -> IO (Either BrowserError Value)
callBrowserTool reg scope toolName args = do
  eInstance <- ensureBrowserInstance reg scope
  case eInstance of
    Left err -> pure (Left (browserCallFailed ("browser unavailable: " <> err)))
    Right instance' -> do
      r <- mcpCallTool instance'.biClient toolName args
      case r of
        Left err | err.mcpErrorKind == McpSessionError -> do
          setCamoSession reg scope Nothing
          reinit <- mcpInitialize instance'.biClient
          case reinit of
            Right () -> first browserErrorFromMcp <$> mcpCallTool instance'.biClient toolName args
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
                "browser instance lost; rebuilt for this turn's next call (was: "
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
        modifyTVar' reg.brSessionLocks (Map.filterWithKey (\scope _ -> browserScopeGroup scope /= gid))
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
  atomically $ modifyTVar' reg.brSessionLocks (Map.delete scope)

-- | Tear down every browser container.  Used by the top-level bracket
-- in @main@ on bot exit.
destroyAllBrowsers :: BrowserRegistry -> IO ()
destroyAllBrowsers reg = do
  entries <- Map.elems <$> readTVarIO reg.brEntries
  for_ entries (releaseBrowser reg)
  atomically $ do
    writeTVar reg.brInstances Map.empty
    writeTVar reg.brCamoSessions Map.empty
    writeTVar reg.brSessionLocks Map.empty
    writeTVar reg.brStartLocks Map.empty

releaseBrowser :: BrowserRegistry -> BrowserEntry -> IO ()
releaseBrowser reg entry =
  releaseRegistered
    (runRm entry.beContainer)
    (atomically $ modifyTVar' reg.brEntries (Map.delete entry.beGroup))
