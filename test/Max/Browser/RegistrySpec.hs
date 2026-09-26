module Max.Browser.RegistrySpec (spec) where

import Control.Concurrent (forkIO, killThread, threadDelay)
import Control.Concurrent.Async (cancel, mapConcurrently, mapConcurrently_, wait, withAsync)
import Control.Concurrent.MVar
import Control.Concurrent.STM qualified as STM
import Control.Exception (finally)
import Control.Monad (forM_, replicateM, when, (>=>))
import Data.Aeson (encode, object, (.=))
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy qualified as LBS
import Data.Either (isLeft, isRight)
import Data.IORef (atomicModifyIORef', modifyIORef', newIORef, readIORef)
import Data.Text qualified as T
import Effectful (runEff)
import Max.Browser.Client (runBrowserWithRegistry)
import Max.Browser.Error (browserErrorMessage)
import Max.Browser.Registry (BrowserRegistry, browserScopeForTask, browserScopeForTurn, callBrowserTool, getCamoSession, newBrowserRegistry, newBrowserRegistryWithHost, newBrowserRegistryWithHosts, releaseBrowserScope, retryBrowserReleases, setCamoSession, tryWithBrowserWorkspace, withBrowserSession, withBrowserWorkspace)
import Max.Browser.ToolRuntime (browserToolsAt)
import Max.Effects.Browser (SessionMethod (..), sessionRequest)
import Max.Effects.ToolOutput (newToolOutputQueue, runToolOutput)
import Max.Effects.Tools (toolRun)
import Max.HttpRuntime (httpRuntimeFromManagers, newHttpRuntime)
import Max.Turn.Types (AgentTurnId (..))
import Network.HTTP.Client (ManagerSettings (..), defaultManagerSettings, makeConnection, newManager)
import OneBot.Types (GroupId (..))
import System.Timeout (timeout)
import Test.Hspec

spec :: Spec
spec = describe "withBrowserSession" $ do
  it "bounds concurrent workspace startups before any excess MCP child can start" $ do
    gate <- newEmptyMVar
    connections <- STM.newTVarIO (0 :: Int)
    refused <- STM.newTVarIO (0 :: Int)
    registry <- capacityRegistry $ do
      STM.atomically (STM.modifyTVar' connections (+ 1))
      readMVar gate
      pure browserOk
    let scopes = [browserScopeForTurn (GroupId 1) (AgentTurnId n) | n <- [1 .. 20]]
        invoke scope = withBrowserSession registry scope $ do
          result <- callBrowserTool registry scope "fixture" (object [])
          when (isLeft result) (STM.atomically (STM.modifyTVar' refused (+ 1)))
          pure result
    withAsync (mapConcurrently invoke scopes) $ \worker -> do
      timeout
        1_000_000
        ( STM.atomically $ do
            started <- STM.readTVar connections
            rejected <- STM.readTVar refused
            STM.check (started == 4 && rejected == 16)
        )
        `shouldReturn` Just ()
      withAsync (invoke (browserScopeForTurn (GroupId 2) (AgentTurnId 1))) $ \otherGroup -> do
        timeout 1_000_000 (STM.atomically (STM.readTVar connections >>= STM.check . (== 5))) `shouldReturn` Just ()
        putMVar gate ()
        wait otherGroup >>= (`shouldSatisfy` isRight)
        results <- wait worker
        length (filter isRight results) `shouldBe` 4
        [browserErrorMessage err | Left err <- results]
          `shouldSatisfy` all (T.isInfixOf "4 browser workspaces")
    -- Two handshake requests and one tool request per admitted workspace.
    STM.readTVarIO connections `shouldReturn` 15

  it "reuses an occupied workspace and only admits another after successful cleanup" $ do
    connections <- newIORef (0 :: Int)
    failClose <- newIORef False
    registry <- capacityRegistry $ do
      atomicModifyIORef' connections (\n -> (n + 1, ()))
      failing <- readIORef failClose
      pure (if failing then browserFailure else browserOk)
    let scope n
          | n < 3 = browserScopeForTurn (GroupId 1) (AgentTurnId n)
          | otherwise = browserScopeForTask (GroupId 1) n 0
        invoke n = withBrowserSession registry (scope n) (callBrowserTool registry (scope n) "fixture" (object []))
    forM_ [1 .. 4] (invoke >=> (`shouldSatisfy` isRight))
    invoke 1 >>= (`shouldSatisfy` isRight)
    readIORef connections `shouldReturn` 13
    invoke 5 >>= (`shouldSatisfy` isLeft)
    readIORef connections `shouldReturn` 13
    modifyIORef' failClose (const True)
    releaseBrowserScope registry (scope 1)
    invoke 5 >>= (`shouldSatisfy` isLeft)
    readIORef connections `shouldReturn` 14
    modifyIORef' failClose (const False)
    retryBrowserReleases registry
    invoke 5 >>= (`shouldSatisfy` isRight)
    readIORef connections `shouldReturn` 19

  it "reclaims a cancelled startup without retiring siblings or leaking capacity" $ do
    connections <- STM.newTVarIO (0 :: Int)
    entered <- newEmptyMVar
    gate <- newEmptyMVar
    registry <- capacityRegistry $ do
      n <- STM.atomically $ do
        STM.modifyTVar' connections (+ 1)
        STM.readTVar connections
      -- Three already-live siblings consume the first nine connections.
      when (n == 10) (putMVar entered () >> takeMVar gate)
      pure browserOk
    let scope n = browserScopeForTask (GroupId 1) n 0
        invoke n = withBrowserSession registry (scope n) (callBrowserTool registry (scope n) "fixture" (object []))
    forM_ [1 .. 3] (invoke >=> (`shouldSatisfy` isRight))
    withAsync (invoke 4) $ \worker -> do
      timeout 1_000_000 (takeMVar entered) `shouldReturn` Just ()
      invoke 5 >>= (`shouldSatisfy` isLeft)
      cancel worker
    invoke 5 >>= (`shouldSatisfy` isRight)
    invoke 1 >>= (`shouldSatisfy` isRight)
    STM.readTVarIO connections `shouldReturn` 14

  it "recreates transport once, clears the page and never replays a lost click" $ do
    let group = GroupId 1
        scope = browserScopeForTurn group (AgentTurnId 1)
        rpc value = LBS.toStrict (encode (object ["jsonrpc" .= ("2.0" :: String), "result" .= value]))
        ok = rpc (object ["ok" .= True])
        started sid = rpc (object ["structuredContent" .= object ["sessionId" .= (sid :: String)]])
        page = rpc (object ["structuredContent" .= object ["url" .= ("https://example.test/" :: String), "text" .= ("fixture" :: String)]])
    replies <- newIORef [ok, ok, started "old-page", page, BS8.empty, ok, ok, ok, started "new-page", page]
    opens <- newIORef (0 :: Int)
    writes <- newIORef []
    manager <-
      newManager
        defaultManagerSettings
          { managerIdleConnectionCount = 0,
            managerRetryableException = const False,
            managerRawConnection = pure $ \_ _ _ -> do
              n <- atomicModifyIORef' opens (\value -> (value + 1, value + 1))
              body <- atomicModifyIORef' replies $ \case [] -> ([], BS8.empty); reply : rest -> (rest, reply)
              let sessionHeader = if n < 7 then "dead-transport" else "new-transport"
              chunks <- newIORef [if BS8.null body then BS8.empty else "HTTP/1.1 200 OK\r\nMcp-Session-Id: " <> sessionHeader <> "\r\nContent-Length: " <> BS8.pack (show (BS8.length body)) <> "\r\n\r\n" <> body]
              makeConnection
                (atomicModifyIORef' chunks $ \case [] -> ([], BS8.empty); chunk : rest -> (rest, chunk))
                (\bytes -> modifyIORef' writes (<> [(n, bytes)]))
                (pure ())
          }
    registry <- newBrowserRegistryWithHost (httpRuntimeFromManagers manager manager manager) group "http://example.test/mcp" "localhost:8931"
    browser <- case browserToolsAt scope registry Nothing of
      first : _ -> pure first
      [] -> fail "missing browser runner"
    let invoke action fields = runEff $ do
          queue <- newToolOutputQueue 0
          runToolOutput queue (toolRun browser (object (("action" .= (action :: String)) : fields)))
        succeeded = either (const False) (const True)
    invoke "open" ["url" .= ("https://example.test/" :: String)] >>= (`shouldSatisfy` succeeded)
    getCamoSession registry scope `shouldReturn` Just "old-page"
    invoke "click" ["selector" .= ("#effect" :: String)] >>= (`shouldSatisfy` either (T.isInfixOf "not replayed") (const False))
    getCamoSession registry scope `shouldReturn` Nothing
    readIORef opens `shouldReturn` 8
    invoke "click" ["selector" .= ("#effect" :: String)] >>= (`shouldSatisfy` either (T.isInfixOf "action=open") (const False))
    readIORef opens `shouldReturn` 8
    invoke "open" ["url" .= ("https://example.test/" :: String)] >>= (`shouldSatisfy` succeeded)
    getCamoSession registry scope `shouldReturn` Just "new-page"
    readIORef opens `shouldReturn` 10
    requests <- readIORef writes
    let requestAt n = BS8.concat [bytes | (index, bytes) <- requests, index == n]
    requestAt 5 `shouldSatisfy` BS8.isInfixOf "browse_session_action"
    requestAt 7 `shouldSatisfy` (not . BS8.isInfixOf "Mcp-Session-Id")
    requestAt 10 `shouldSatisfy` BS8.isInfixOf "new-page"
    BS8.concat [bytes | (index, bytes) <- requests, index > 5]
      `shouldSatisfy` (not . BS8.isInfixOf "browse_session_action")

  it "binds session identity and checks the effective action after duplicate fields" $ do
    let group = GroupId 1
        scope = browserScopeForTurn group (AgentTurnId 1)
        body = "{\"jsonrpc\":\"2.0\",\"result\":{\"ok\":true}}"
    writes <- newIORef []
    manager <-
      newManager
        defaultManagerSettings
          { managerIdleConnectionCount = 0,
            managerRawConnection = pure $ \_ _ _ -> do
              chunks <- newIORef ["HTTP/1.1 200 OK\r\nMcp-Session-Id: fixture\r\nContent-Length: " <> BS8.pack (show (BS8.length body)) <> "\r\n\r\n" <> body]
              makeConnection
                (atomicModifyIORef' chunks $ \case [] -> ([], BS8.empty); chunk : rest -> (rest, chunk))
                (\bytes -> modifyIORef' writes (<> [bytes]))
                (pure ())
          }
    registry <- newBrowserRegistryWithHost (httpRuntimeFromManagers manager manager manager) group "http://example.test/mcp" "localhost:8931"
    setCamoSession registry scope (Just "owned-page")
    let request method fields = runEff $ runBrowserWithRegistry scope registry Nothing (sessionRequest method fields)
    request SessionSnapshot ["sessionId" .= ("foreign-page" :: String)] >>= (`shouldSatisfy` either (const False) (const True))
    sent <- BS8.concat <$> readIORef writes
    sent `shouldSatisfy` BS8.isInfixOf "owned-page"
    sent `shouldSatisfy` (not . BS8.isInfixOf "foreign-page")
    let action kind = "action" .= object ["type" .= (kind :: String)]
    request SessionAction [action "click", action "evaluate"]
      `shouldReturn` Left "evaluate requires a browser agent; use the agent tool with profile=browser"
    BS8.concat <$> readIORef writes `shouldReturn` sent

  it "keeps failed foreground cleanup fenced and retries closure without replaying tools" $ do
    let success = "{\"jsonrpc\":\"2.0\",\"result\":{\"ok\":true}}"
        failure = "{\"jsonrpc\":\"2.0\",\"result\":{\"isError\":true,\"content\":[]}}"
        group = GroupId 1
        scope = browserScopeForTurn group (AgentTurnId 1)
    replies <- newIORef [success, success, success, failure, success, success]
    opens <- newIORef (0 :: Int)
    manager <-
      newManager
        defaultManagerSettings
          { managerIdleConnectionCount = 0,
            managerRetryableException = const False,
            managerRawConnection = pure $ \_ _ _ -> do
              modifyIORef' opens (+ 1)
              body <- atomicModifyIORef' replies $ \case [] -> ([], BS8.empty); reply : rest -> (rest, reply)
              chunks <- newIORef ["HTTP/1.1 200 OK\r\nMcp-Session-Id: fixture\r\nContent-Length: " <> BS8.pack (show (BS8.length body)) <> "\r\n\r\n" <> body]
              makeConnection
                (atomicModifyIORef' chunks $ \case [] -> ([], BS8.empty); chunk : rest -> (rest, chunk))
                (const (pure ()))
                (pure ())
          }
    registry <- newBrowserRegistryWithHost (httpRuntimeFromManagers manager manager manager) group "http://example.test/mcp" "localhost:8931"
    callBrowserTool registry scope "fixture" (object []) >>= (`shouldSatisfy` either (const False) (const True))
    setCamoSession registry scope (Just "fixture")
    releaseBrowserScope registry scope
    getCamoSession registry scope `shouldReturn` Just "fixture"
    callBrowserTool registry scope "fixture" (object []) >>= (`shouldSatisfy` either (const True) (const False))
    readIORef opens `shouldReturn` 4
    retryBrowserReleases registry
    getCamoSession registry scope `shouldReturn` Nothing
    readIORef opens `shouldReturn` 6
    retryBrowserReleases registry
    readIORef opens `shouldReturn` 6

  it "keeps task generations separate while serializing ownership across generations" $ do
    reg <- testRegistry
    browserScopeForTask (GroupId 1) 9 1 `shouldNotBe` browserScopeForTask (GroupId 1) 9 2
    browserScopeForTask (GroupId 1) 9 1 `shouldNotBe` browserScopeForTask (GroupId 1) 10 1
    withBrowserWorkspace reg 9 $ do
      tryWithBrowserWorkspace reg 9 (pure ()) `shouldReturn` Nothing
      tryWithBrowserWorkspace reg 10 (pure ()) `shouldReturn` Just ()
    tryWithBrowserWorkspace reg 9 (pure ()) `shouldReturn` Just ()

  it "serializes complete operations inside one turn" $ do
    reg <- testRegistry
    let scope = browserScopeForTurn (GroupId 1) (AgentTurnId 1)
    counters <- newMVar (0 :: Int, 0 :: Int)
    done <- replicateM 4 $ do
      finished <- newEmptyMVar
      _ <- forkIO $ operation reg scope counters `finally` putMVar finished ()
      pure finished

    forM_ done takeMVar
    (_, peak) <- takeMVar counters
    peak `shouldBe` 1

  forM_
    [ ("sibling turns in the same group", [(GroupId 1, AgentTurnId 1), (GroupId 1, AgentTurnId 2)]),
      ("different groups", [(GroupId 1, AgentTurnId 1), (GroupId 2, AgentTurnId 1)])
    ]
    $ \(label, owners) -> it ("allows " <> label <> " to operate concurrently") $ do
      reg <- testRegistry
      entered <- newIORef (0 :: Int)
      bothEntered <- newEmptyMVar
      release <- newEmptyMVar
      let operate (group, turn) =
            withBrowserSession reg (browserScopeForTurn group turn) $ do
              n <- atomicModifyIORef' entered (\x -> let next = x + 1 in (next, next))
              when (n == 2) (putMVar bothEntered ())
              takeMVar release
      withAsync (mapConcurrently_ operate owners) $ \worker -> do
        timeout 1_000_000 (takeMVar bothEntered) `shouldReturn` Just ()
        forM_ owners (const (putMVar release ()))
        wait worker
      readIORef entered `shouldReturn` 2

  it "releases a turn lock when its owner is cancelled" $ do
    reg <- testRegistry
    let scope = browserScopeForTurn (GroupId 1) (AgentTurnId 1)
    entered <- newEmptyMVar
    blocked <- newEmptyMVar
    finished <- newEmptyMVar
    owner <-
      forkIO $
        withBrowserSession reg scope (putMVar entered () >> takeMVar blocked)
          `finally` putMVar finished ()

    takeMVar entered
    killThread owner
    takeMVar finished
    timeout 1_000_000 (withBrowserSession reg scope (pure ()))
      `shouldReturn` Just ()
  where
    operation reg scope counters =
      withBrowserSession reg scope $ do
        modifyMVar_ counters $ \(active, peak) ->
          let next = active + 1
           in pure (next, max peak next)
        threadDelay 20_000
        modifyMVar_ counters $ \(active, peak) -> pure (active - 1, peak)

testRegistry :: IO BrowserRegistry
testRegistry = do
  runtime <- newHttpRuntime
  newBrowserRegistry runtime

browserOk, browserFailure :: BS8.ByteString
browserOk = "{\"jsonrpc\":\"2.0\",\"result\":{\"ok\":true}}"
browserFailure = "{\"jsonrpc\":\"2.0\",\"result\":{\"isError\":true,\"content\":[]}}"

capacityRegistry :: IO BS8.ByteString -> IO BrowserRegistry
capacityRegistry response = do
  manager <-
    newManager
      defaultManagerSettings
        { managerIdleConnectionCount = 0,
          managerRetryableException = const False,
          managerRawConnection = pure $ \_ _ _ -> do
            body <- response
            chunks <- newIORef ["HTTP/1.1 200 OK\r\nMcp-Session-Id: fixture\r\nContent-Length: " <> BS8.pack (show (BS8.length body)) <> "\r\n\r\n" <> body]
            makeConnection
              (atomicModifyIORef' chunks $ \case [] -> ([], BS8.empty); chunk : rest -> (rest, chunk))
              (const (pure ()))
              (pure ())
        }
  newBrowserRegistryWithHosts (httpRuntimeFromManagers manager manager manager) [(GroupId n, "http://example.test/mcp", "localhost:8931") | n <- [1, 2]]
