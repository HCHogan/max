-- |
-- Per-group browser registry: one camoufox-MCP container per
-- 'GroupId', created lazily on the first browser tool call and reused
-- across dispatches, torn down on @!clear --all@ or bot exit.  Mirrors
-- "Max.Sandbox.Registry"; we reuse its @docker@ helpers for teardown
-- and boot-time reaping of the @max-br-@ namespace.
--
-- The browser page state lives in a camoufox /browse session/ inside
-- the MCP server (created by @browse_session_start@, addressed by a
-- @sessionId@ that every @browse_session_*@ call must carry), so it is
-- inherently stateful and shared within a group — parallel dispatches
-- drive the same page.  The registry tracks that per-group @sessionId@
-- alongside the container; "Max.Tools.Browser" injects it into tool
-- arguments.  Container creation is serialized by a global start lock;
-- the readiness wait happens under it, which is fine for a
-- single-tenant bot.
module Max.Browser.Registry
  ( BrowserRegistry,
    brProxy,
    newBrowserRegistry,
    reapStaleBrowsers,
    callBrowserTool,
    getCamoSession,
    setCamoSession,
    destroyBrowsersForGroup,
    destroyAllBrowsers,
    browserNamePrefix,
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM
import Control.Exception (bracket_)
import Control.Monad (void)
import Data.Aeson (Value)
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
import Max.MCP.Client (McpClient, mcpCallTool, mcpInitialize, newMcpClient)
import Max.Sandbox.Docker (listContainersByPrefix, runRm)
import Network.HTTP.Client (Manager, defaultManagerSettings, newManager)
import OneBot.Types (GroupId (..))

browserNamePrefix :: Text
browserNamePrefix = "max-br-"

data BrowserEntry = BrowserEntry
  { beGroup :: !GroupId,
    beContainer :: !Text,
    beClient :: !McpClient,
    beCreatedAt :: !UTCTime
  }

data BrowserRegistry = BrowserRegistry
  { brManager :: !Manager,
    -- | Global create lock: only one container is brought up (and
    -- waited on) at a time.
    brStartLock :: !(TMVar ()),
    brEntries :: !(TVar (Map GroupId BrowserEntry)),
    -- | The group's live camoufox browse-session id, if a page is
    -- open.  Kept outside 'BrowserEntry' so the tool layer can read /
    -- update it without racing entry creation.
    brCamoSessions :: !(TVar (Map GroupId Text)),
    -- | Proxy URL every browse session routes through (config
    -- @browser.proxy@); 'Nothing' = direct.  "Max.Tools.Browser"
    -- passes it to @browse_session_start@.
    brProxy :: !(Maybe Text)
  }

newBrowserRegistry :: Maybe Text -> IO BrowserRegistry
newBrowserRegistry proxy = do
  mgr <- newManager defaultManagerSettings
  BrowserRegistry mgr <$> newTMVarIO () <*> newTVarIO Map.empty <*> newTVarIO Map.empty <*> pure proxy

-- | The group's current camoufox browse-session id, if any.
getCamoSession :: BrowserRegistry -> GroupId -> IO (Maybe Text)
getCamoSession reg gid = Map.lookup gid <$> readTVarIO reg.brCamoSessions

-- | Record ('Just') or forget ('Nothing') the group's browse-session id.
setCamoSession :: BrowserRegistry -> GroupId -> Maybe Text -> IO ()
setCamoSession reg gid msid =
  atomically . modifyTVar' reg.brCamoSessions $
    maybe (Map.delete gid) (Map.insert gid) msid

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
  m <- readTVarIO reg.brEntries
  case Map.lookup gid m of
    Just e -> pure (Right e)
    Nothing ->
      bracket_
        (atomically $ takeTMVar reg.brStartLock)
        (atomically $ putTMVar reg.brStartLock ())
        $ do
          -- Re-check under the lock: another dispatch may have won.
          m2 <- readTVarIO reg.brEntries
          case Map.lookup gid m2 of
            Just e -> pure (Right e)
            Nothing -> createEntry reg gid

createEntry :: BrowserRegistry -> GroupId -> IO (Either Text BrowserEntry)
createEntry reg gid = do
  now <- getCurrentTime
  let GroupId raw = gid
      name = browserNamePrefix <> T.pack (show raw)
  runRes <- runRunBrowser name defaultBrowserImage
  case runRes of
    Left err -> pure (Left err)
    Right _cid -> do
      portRes <- browserHostPort name
      case portRes of
        Left err -> runRm name >> pure (Left err)
        Right port -> do
          let endpoint = "http://127.0.0.1:" <> show port <> "/mcp"
              -- supergateway does no Host validation; send the
              -- container-internal bind anyway so a future server
              -- with a rebinding guard (as playwright-mcp had) works.
              hostHeader = "localhost:" <> show containerPort
          client <- newMcpClient reg.brManager endpoint hostHeader
          ready <- waitReady client
          case ready of
            Left err -> runRm name >> pure (Left err)
            Right () -> do
              let entry =
                    BrowserEntry
                      { beGroup = gid,
                        beContainer = name,
                        beClient = client,
                        beCreatedAt = now
                      }
              atomically $ modifyTVar' reg.brEntries (Map.insert gid entry)
              pure (Right entry)

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

-- | Ensure the group's browser is up, then invoke one MCP tool on it.
--
-- Resilience: the MCP session can be lost out from under us (server
-- recycles it, the gateway restarts, memory pressure).  On that we
-- re-run the @initialize@ handshake once and retry; if even that fails
-- the container is unhealthy, so we tear it down and report — the next
-- call rebuilds a fresh one.  Re-initializing makes supergateway spawn
-- a *fresh* camoufox-mcp child, so any camoufox browse session died
-- with the old one — forget it, the tool layer will start a new one.
callBrowserTool :: BrowserRegistry -> GroupId -> Text -> Value -> IO (Either Text Value)
callBrowserTool reg gid toolName args = do
  eEntry <- ensureBrowserForGroup reg gid
  case eEntry of
    Left err -> pure (Left ("browser unavailable: " <> err))
    Right e -> do
      r <- mcpCallTool e.beClient toolName args
      case r of
        Left err | sessionLost err -> do
          setCamoSession reg gid Nothing
          reinit <- mcpInitialize e.beClient
          case reinit of
            Right () -> mcpCallTool e.beClient toolName args
            Left _ -> do
              _ <- destroyBrowsersForGroup reg gid
              pure (Left ("browser session lost; rebuilt for next call (was: " <> err <> ")"))
        _ -> pure r
  where
    -- Match the gateway's MCP-session-validation failures (see
    -- Max.MCP.Client error text): supergateway 400s "Bad Request: No
    -- valid session ID provided" for an unknown/expired session; the
    -- playwright-era "Session not found" / "not initialized" spellings
    -- are kept as belt-and-suspenders.
    sessionLost err =
      "No valid session ID" `T.isInfixOf` err
        || "Session not found" `T.isInfixOf` err
        || "not initialized" `T.isInfixOf` err

--------------------------------------------------------------------------------
-- Teardown.

-- | Destroy the group's browser container (if any).  Returns how many
-- were removed (0 or 1).  Used by @!clear --all@.
destroyBrowsersForGroup :: BrowserRegistry -> GroupId -> IO Int
destroyBrowsersForGroup reg gid = do
  mEntry <- atomically $ do
    m <- readTVar reg.brEntries
    let (mine, rest) = Map.partition (\e -> e.beGroup == gid) m
    writeTVar reg.brEntries rest
    modifyTVar' reg.brCamoSessions (Map.delete gid)
    pure (Map.elems mine)
  for_ mEntry $ \e -> runRm e.beContainer
  pure (length mEntry)

-- | Tear down every browser container.  Used by the top-level bracket
-- in @main@ on bot exit.
destroyAllBrowsers :: BrowserRegistry -> IO ()
destroyAllBrowsers reg = do
  entries <- atomically $ do
    m <- readTVar reg.brEntries
    writeTVar reg.brEntries Map.empty
    writeTVar reg.brCamoSessions Map.empty
    pure (Map.elems m)
  void $ for_ entries $ \e -> runRm e.beContainer
