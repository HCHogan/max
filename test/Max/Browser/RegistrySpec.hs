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
import Control.Monad (forM, forM_)
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Max.Browser.Registry (newBrowserRegistry, withBrowserSession)
import OneBot.Types (GroupId (..))
import System.Timeout (timeout)
import Test.Hspec

spec :: Spec
spec = describe "withBrowserSession" $ do
  it "serializes complete operations for the same group" $ do
    reg <- newBrowserRegistry Nothing
    counters <- newMVar (0 :: Int, 0 :: Int)
    done <- forM [1 .. 4 :: Int] $ \_ -> do
      finished <- newEmptyMVar
      _ <- forkIO $ operation reg counters `finally` putMVar finished ()
      pure finished

    forM_ done takeMVar
    (_, peak) <- takeMVar counters
    peak `shouldBe` 1

  it "allows different groups to operate concurrently" $ do
    reg <- newBrowserRegistry Nothing
    entered <- newIORef (0 :: Int)
    bothEntered <- newEmptyMVar
    release <- newEmptyMVar
    done <- forM [GroupId 1, GroupId 2] $ \gid -> do
      finished <- newEmptyMVar
      _ <-
        forkIO $
          withBrowserSession
            reg
            gid
            ( do
                n <- atomicModifyIORef' entered (\x -> let next = x + 1 in (next, next))
                if n == 2 then putMVar bothEntered () else pure ()
                takeMVar release
            )
            `finally` putMVar finished ()
      pure finished

    timeout 1_000_000 (takeMVar bothEntered) `shouldReturn` Just ()
    putMVar release ()
    putMVar release ()
    forM_ done takeMVar
    readIORef entered `shouldReturn` 2

  it "releases a group lock when its owner is cancelled" $ do
    reg <- newBrowserRegistry Nothing
    entered <- newEmptyMVar
    blocked <- newEmptyMVar
    finished <- newEmptyMVar
    owner <-
      forkIO $
        withBrowserSession reg (GroupId 1) (putMVar entered () >> takeMVar blocked)
          `finally` putMVar finished ()

    takeMVar entered
    killThread owner
    takeMVar finished
    timeout 1_000_000 (withBrowserSession reg (GroupId 1) (pure ()))
      `shouldReturn` Just ()
  where
    operation reg counters =
      withBrowserSession reg (GroupId 1) $ do
        modifyMVar_ counters $ \(active, peak) ->
          let next = active + 1
           in pure (next, max peak next)
        threadDelay 20_000
        modifyMVar_ counters $ \(active, peak) -> pure (active - 1, peak)
