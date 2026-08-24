module Max.Worker.GenerationSpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, cancel, waitCatch)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM (STM, atomically, newEmptyTMVarIO, newTVarIO, putTMVar, readTMVar, readTVarIO, retry, writeTVar)
import Control.Exception (finally, throwIO)
import Data.IORef (newIORef, readIORef, writeIORef)
import Max.Worker.Generation
import Test.Hspec

spec :: Spec
spec = describe "reloadable worker generations" $ do
  it "leaves the active worker untouched when preparation fails" $ do
    oldStopped <- newIORef False
    supervisor <- newGenerationSupervisor 1 (foreverWorker `finally` writeIORef oldStopped True)
    prepared <- prepareGeneration 2 (throwIO (userError "candidate secret must not escape"))
    case prepared of
      Left failure -> failure `shouldBe` PrepareFailure
      Right _ -> expectationFailure "failing preparation produced a worker"
    activeWorkerGeneration supervisor `shouldReturn` 1
    readIORef oldStopped `shouldReturn` False
    closeGenerationSupervisor supervisor

  it "does not start a prepared worker before the atomic publication gate" $ do
    started <- newIORef False
    supervisor <- newGenerationSupervisor 1 foreverWorker
    Right prepared <- prepareGeneration 2 (pure (writeIORef started True >> foreverWorker))
    threadDelay 20_000
    readIORef started `shouldReturn` False
    published <- newTVarIO (0 :: Int)
    (result, retired) <- commitGeneration supervisor prepared (writeTVar published 1 >> pure (7 :: Int))
    result `shouldBe` 7
    retired `shouldBe` Retired
    eventually (readIORef started) `shouldReturn` True
    readTVarIO published `shouldReturn` 1
    activeWorkerGeneration supervisor `shouldReturn` 2
    closeGenerationSupervisor supervisor

  it "cancels an abandoned prepared worker without publishing it" $ do
    ran <- newIORef False
    supervisor <- newGenerationSupervisor 1 foreverWorker
    Right prepared <- prepareGeneration 2 (pure (writeIORef ran True))
    abortGeneration prepared
    threadDelay 20_000
    readIORef ran `shouldReturn` False
    activeWorkerGeneration supervisor `shouldReturn` 1
    closeGenerationSupervisor supervisor

  it "does not swallow cancellation while candidate preparation is blocked" $ do
    preparationStarted <- newEmptyMVar
    neverReady <- newEmptyMVar
    supervisor <- newGenerationSupervisor 1 foreverWorker
    preparing <- async (prepareGeneration 2 (putMVar preparationStarted () >> takeMVar neverReady >> pure foreverWorker))
    takeMVar preparationStarted
    cancel preparing
    waitCatch preparing >>= expectCancelled
    activeWorkerGeneration supervisor `shouldReturn` 1
    closeGenerationSupervisor supervisor

  it "cancels a candidate blocked before publication and keeps generation one" $ do
    ran <- newIORef False
    supervisor <- newGenerationSupervisor 1 foreverWorker
    Right prepared <- prepareGeneration 2 (pure (writeIORef ran True >> foreverWorker))
    committing <- async (commitGeneration supervisor prepared (retry :: STM ()))
    threadDelay 20_000
    cancel committing
    waitCatch committing >>= expectCancelled
    readIORef ran `shouldReturn` False
    activeWorkerGeneration supervisor `shouldReturn` 1
    closeGenerationSupervisor supervisor

  it "keeps the published replacement active when its caller is cancelled during retirement" $ do
    oldStarted <- newEmptyMVar
    oldCancelling <- newEmptyTMVarIO
    releaseOld <- newEmptyTMVarIO
    let stickyOld =
          putMVar oldStarted ()
            >> (foreverWorker `finally` (atomically (putTMVar oldCancelling ()) >> atomically (readTMVar releaseOld)))
    supervisor <- newGenerationSupervisor 1 stickyOld
    takeMVar oldStarted
    Right prepared <- prepareGeneration 2 (pure foreverWorker)
    published <- newTVarIO False
    committing <- async (commitGeneration supervisor prepared (writeTVar published True))
    atomically (readTMVar oldCancelling)
    readTVarIO published `shouldReturn` True
    cancel committing
    waitCatch committing >>= expectCancelled
    activeWorkerGeneration supervisor `shouldReturn` 2
    atomically (putTMVar releaseOld ())
    closeGenerationSupervisor supervisor

foreverWorker :: IO ()
foreverWorker = threadDelay 60_000_000

eventually :: IO Bool -> IO Bool
eventually check = go (100 :: Int)
  where
    go 0 = check
    go n = do
      ready <- check
      if ready then pure True else threadDelay 1_000 >> go (n - 1)

expectCancelled :: Either a b -> Expectation
expectCancelled = \case
  Left _ -> pure ()
  Right _ -> expectationFailure "operation swallowed asynchronous cancellation"
