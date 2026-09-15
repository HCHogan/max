module Max.Concurrent.LockSpec (spec) where

import Control.Concurrent.Async (cancel, wait, withAsync)
import Control.Concurrent.MVar
import Max.Concurrent.Lock
import System.Timeout (timeout)
import Test.Hspec

spec :: Spec
spec = describe "shared command / exclusive lifecycle access" $ do
  it "admits two commands before either finishes and drains both before lifecycle work" $ do
    gate <- newSharedLock
    firstStarted <- newEmptyMVar
    secondStarted <- newEmptyMVar
    firstDone <- newEmptyMVar
    secondDone <- newEmptyMVar
    lifecycle <- newEmptyMVar
    withAsync (withSharedLock gate (putMVar firstStarted () >> takeMVar firstDone)) $ \first -> do
      timeout 1000000 (takeMVar firstStarted) `shouldReturn` Just ()
      withAsync (withSharedLock gate (putMVar secondStarted () >> takeMVar secondDone)) $ \second -> do
        timeout 1000000 (takeMVar secondStarted) `shouldReturn` Just ()
        withAsync (withExclusiveLock gate (putMVar lifecycle ())) $ \writer -> do
          timeout 50000 (readMVar lifecycle) `shouldReturn` Nothing
          putMVar firstDone ()
          wait first
          timeout 50000 (readMVar lifecycle) `shouldReturn` Nothing
          putMVar secondDone ()
          wait second
          timeout 1000000 (wait writer) `shouldReturn` Just ()

  it "releases command access on cancellation" $ do
    gate <- newSharedLock
    started <- newEmptyMVar
    never <- newEmptyMVar
    withAsync (withSharedLock gate (putMVar started () >> takeMVar never)) $ \command -> do
      takeMVar started
      cancel command
      timeout 1000000 (withExclusiveLock gate (pure ())) `shouldReturn` Just ()

  it "cancelling a draining lifecycle operation reopens admission" $ do
    gate <- newSharedLock
    started <- newEmptyMVar
    never <- newEmptyMVar
    withAsync (withSharedLock gate (putMVar started () >> takeMVar never)) $ \_ -> do
      takeMVar started
      withAsync (withExclusiveLock gate (pure ())) $ \writer -> do
        timeout 50000 (wait writer) `shouldReturn` Nothing
        cancel writer
        timeout 1000000 (withSharedLock gate (pure ())) `shouldReturn` Just ()
