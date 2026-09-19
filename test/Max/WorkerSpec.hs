module Max.WorkerSpec (spec) where

import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (AsyncException (ThreadKilled), SomeException, displayException, throwIO, toException, try)
import Control.Monad (forM_)
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.List (isInfixOf)
import Data.Text (Text)
import Effectful (Eff, IOE, liftIO, runEff)
import Effectful.Concurrent (Concurrent, runConcurrent, threadDelay)
import Effectful.Exception (finally)
import Effectful.Log (Log, LogLevel (LogAttention), runLog)
import Max.Log (ColorMode (..), withCompactLogger)
import Max.Worker (WorkerCriticality (..), recovering, retrying, withWorkers, worker)
import Test.Hspec

supervised :: Eff '[Log, Concurrent, IOE] a -> IO a
supervised act =
  withCompactLogger ColorNever Nothing $ \logger ->
    runEff . runConcurrent . runLog "worker-test" logger LogAttention $ act

spec :: Spec
spec = describe "worker supervision" $ do
  it "fails with the worker name when a required worker returns normally" $ do
    result <-
      try @SomeException . supervised $
        withWorkers
          [worker "event-ingest" RequiredWorker (pure ())]
          (threadDelay 5_000_000)
    result `shouldSatisfy` \case
      Left err -> "required worker exited normally: event-ingest" `isInfixOf` displayException err
      Right () -> False

  it "allows a finite worker to finish" $ do
    finished <- newEmptyMVar
    supervised
      ( withWorkers
          [worker "shutdown-drain" OptionalWorker (liftIO (putMVar finished True))]
          (liftIO (takeMVar finished) <* threadDelay 100_000)
      )
      `shouldReturn` True

  forM_ [RequiredWorker, OptionalWorker] $ \kind ->
    it ("propagates a " <> show kind <> " failure and cancels its siblings") $ do
      started <- newEmptyMVar
      stopped <- newEmptyMVar
      let sibling =
            (liftIO (putMVar started ()) >> threadDelay 5_000_000)
              `finally` liftIO (putMVar stopped ())
          failure = liftIO (takeMVar started >> throwIO (userError "worker failed"))
      result <-
        try @SomeException . supervised $
          withWorkers
            [worker "sibling" RequiredWorker sibling, worker "failure" kind failure]
            (threadDelay 5_000_000)
      result `shouldSatisfy` \case
        Left err -> "worker failed" `isInfixOf` displayException err
        Right () -> False
      takeMVar stopped `shouldReturn` ()

  describe "explicit connection retries" $ do
    it "recovers a maintenance exception without cancelling an unrelated worker" $ do
      attempts <- newIORef (0 :: Int)
      finished <- newEmptyMVar
      supervised $
        withWorkers
          [ worker "core" RequiredWorker (threadDelay 5_000_000),
            worker "maintenance" OptionalWorker $ do
              recovering "maintenance read" $ liftIO $ do
                n <- atomicModifyIORef' attempts (\count -> (count + 1, count + 1))
                if n == 1 then throwIO (userError "database connection reset") else putMVar finished ()
          ]
          (liftIO (takeMVar finished))
      readIORef attempts `shouldReturn` 2

    it "does not turn maintenance cancellation into a retry" $ do
      attempts <- newIORef (0 :: Int)
      result <- try @SomeException . supervised . recovering "maintenance read" $ liftIO $ do
        atomicModifyIORef' attempts (\count -> (count + 1, ()))
        throwIO ThreadKilled :: IO ()
      result `shouldSatisfy` either (isInfixOf "thread killed" . displayException) (const False)
      readIORef attempts `shouldReturn` 1

    it "retries a recoverable read and returns its result" $ do
      attempts <- newIORef (0 :: Int)
      result <- supervised . retrying "bridge read" $ do
        n <- liftIO (atomicModifyIORef' attempts (\count -> (count + 1, count + 1)))
        pure (if n == 1 then Left "bridge unavailable" else Right ("cursor-42" :: String))
      result `shouldBe` "cursor-42"
      readIORef attempts `shouldReturn` 2

    forM_ [("synchronous failure", toException (userError "unexpected failure")), ("cancellation", toException ThreadKilled)] $ \(label, failure) ->
      it ("propagates " <> label <> " without retry") $ do
        attempts <- newIORef (0 :: Int)
        result <- try @SomeException . supervised . retrying "bridge read" $ do
          liftIO (atomicModifyIORef' attempts (\count -> (count + 1, ())))
          liftIO (throwIO failure) :: Eff '[Log, Concurrent, IOE] (Either Text ())
        result `shouldSatisfy` \case
          Left err -> displayException failure `isInfixOf` displayException err
          Right () -> False
        readIORef attempts `shouldReturn` 1
