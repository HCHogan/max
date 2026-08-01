module Max.ResourceSpec (spec) where

import Control.Concurrent
  ( forkIO,
    newEmptyMVar,
    putMVar,
    takeMVar,
    throwTo,
  )
import Control.Exception (AsyncException (ThreadKilled), finally)
import Control.Monad (void)
import Data.IORef (newIORef, readIORef, writeIORef)
import Max.Resource (acquireRegistered, releaseRegistered)
import System.Timeout (timeout)
import Test.Hspec

spec :: Spec
spec = describe "registered resource ownership" $ do
  it "rolls back a partially acquired resource when acquisition is cancelled" $ do
    started <- newEmptyMVar
    blockAcquire <- newEmptyMVar
    rolledBack <- newEmptyMVar
    finished <- newEmptyMVar
    registered <- newIORef False

    tid <-
      forkFinally
        ( acquireRegistered
            (putMVar started () >> takeMVar blockAcquire >> pure (Right ()))
            (putMVar rolledBack ())
            (const (writeIORef registered True))
        )
        finished
    takeMVar started
    throwTo tid ThreadKilled

    timeout 1_000_000 (takeMVar rolledBack) `shouldReturn` Just ()
    timeout 1_000_000 (takeMVar finished) `shouldReturn` Just ()
    readIORef registered `shouldReturn` False

  it "keeps ownership registered when physical cleanup is cancelled" $ do
    cleanupStarted <- newEmptyMVar
    blockCleanup <- newEmptyMVar
    finished <- newEmptyMVar
    registered <- newIORef True

    tid <-
      forkFinally
        ( releaseRegistered
            (putMVar cleanupStarted () >> takeMVar blockCleanup)
            (writeIORef registered False)
        )
        finished
    takeMVar cleanupStarted
    throwTo tid ThreadKilled

    timeout 1_000_000 (takeMVar finished) `shouldReturn` Just ()
    readIORef registered `shouldReturn` True
  where
    forkFinally action finished =
      forkIO (void action `finally` putMVar finished ())
