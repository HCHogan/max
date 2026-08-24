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
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Max.Browser.Registry (BrowserRegistry, browserScopeForTurn, newBrowserRegistry, withBrowserSession)
import Max.HttpRuntime (newHttpRuntime)
import Max.Turn.Types (AgentTurnId (..))
import OneBot.Types (GroupId (..))
import System.Timeout (timeout)
import Test.Hspec

spec :: Spec
spec = describe "withBrowserSession" $ do
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
