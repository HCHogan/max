module Max.Browser.RegistrySpec (spec) where

import Control.Concurrent (forkIO, killThread, threadDelay)
import Control.Concurrent.MVar
  ( modifyMVar_,
    newEmptyMVar,
    newMVar,
    putMVar,
    takeMVar,
  )
import Control.Exception (finally)
import Control.Monad (forM, forM_, replicateM, when)
import Data.Aeson (object)
import Data.ByteString.Char8 qualified as BS8
import Data.IORef (atomicModifyIORef', modifyIORef', newIORef, readIORef)
import Max.Browser.Registry (BrowserRegistry, browserScopeForTask, browserScopeForTurn, callBrowserTool, getCamoSession, newBrowserRegistry, newBrowserRegistryWithHost, releaseBrowserScope, retryBrowserReleases, setCamoSession, tryWithBrowserWorkspace, withBrowserSession, withBrowserWorkspace)
import Max.HttpRuntime (httpRuntimeFromManagers, newHttpRuntime)
import Max.Turn.Types (AgentTurnId (..))
import Network.HTTP.Client (ManagerSettings (..), defaultManagerSettings, makeConnection, newManager)
import OneBot.Types (GroupId (..))
import System.Timeout (timeout)
import Test.Hspec

spec :: Spec
spec = describe "withBrowserSession" $ do
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

  it "allows sibling turns in the same group to operate concurrently" $ do
    reg <- testRegistry
    entered <- newIORef (0 :: Int)
    bothEntered <- newEmptyMVar
    release <- newEmptyMVar
    done <- forM [AgentTurnId 1, AgentTurnId 2] $ \turn -> do
      finished <- newEmptyMVar
      _ <-
        forkIO $
          withBrowserSession
            reg
            (browserScopeForTurn (GroupId 1) turn)
            ( do
                n <- atomicModifyIORef' entered (\x -> let next = x + 1 in (next, next))
                when (n == 2) (putMVar bothEntered ())
                takeMVar release
            )
            `finally` putMVar finished ()
      pure finished

    timeout 1_000_000 (takeMVar bothEntered) `shouldReturn` Just ()
    putMVar release ()
    putMVar release ()
    forM_ done takeMVar
    readIORef entered `shouldReturn` 2

  it "allows different groups to operate concurrently" $ do
    reg <- testRegistry
    entered <- newIORef (0 :: Int)
    bothEntered <- newEmptyMVar
    release <- newEmptyMVar
    done <- forM [GroupId 1, GroupId 2] $ \gid -> do
      finished <- newEmptyMVar
      _ <-
        forkIO $
          withBrowserSession
            reg
            (browserScopeForTurn gid (AgentTurnId 1))
            ( do
                n <- atomicModifyIORef' entered (\x -> let next = x + 1 in (next, next))
                when (n == 2) (putMVar bothEntered ())
                takeMVar release
            )
            `finally` putMVar finished ()
      pure finished

    timeout 1_000_000 (takeMVar bothEntered) `shouldReturn` Just ()
    putMVar release ()
    putMVar release ()
    forM_ done takeMVar
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
