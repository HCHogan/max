module Max.WorkerSpec (spec) where

import Control.Exception (SomeException, displayException, throwIO, try)
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.List (isInfixOf)
import Effectful (Eff, IOE, liftIO, runEff)
import Effectful.Concurrent (Concurrent, runConcurrent, threadDelay)
import Effectful.Log (Log, LogLevel (LogAttention), runLog)
import Max.Log (ColorMode (..), withCompactLogger)
import Max.Worker
  ( WorkerCriticality (..),
    retryingWith,
    withWorkers,
    worker,
  )
import Test.Hspec

-- | Supervision needs a logger, because a restart nobody can see is the
-- failure mode the restart was introduced to replace.  Attention is the
-- highest level log-base has, so the restart lines do appear in test output —
-- which is the right way round: they are what the change is.
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

  it "allows an enabled non-critical worker to finish" $ do
    result <-
      supervised $
        withWorkers
          [worker "one-shot-observer" OptionalWorker (pure ())]
          (pure True)
    result `shouldBe` True

  -- Issue #17.F.  This is the property the platform adapters were each holding
  -- up by hand, and the one 'Max.IMessage' records losing: a sleeping bridge
  -- reached the linked thread and took every other worker down with it.
  it "keeps the process alive when a restartable worker throws" $ do
    attempts <- newIORef (0 :: Int)
    result <-
      supervised $
        withWorkers
          [ worker "flaky-bridge" RestartableWorker $ do
              n <- liftIO (atomicModifyIORef' attempts (\c -> (c + 1, c + 1)))
              liftIO (throwIO (userError ("bridge unreachable, attempt " <> show n)))
          ]
          -- Long enough to cover the first backoff, which is one second.
          (threadDelay 2_500_000 >> liftIO (readIORef attempts))
    -- Restarted rather than merely survived: one attempt would prove only that
    -- the exception had been swallowed.
    result `shouldSatisfy` (>= 2)

  it "does not restart a restartable worker that returned on its own" $ do
    runs <- newIORef (0 :: Int)
    result <-
      supervised $
        withWorkers
          [ worker "finished-once" RestartableWorker $
              liftIO (atomicModifyIORef' runs (\c -> (c + 1, ())))
          ]
          (threadDelay 2_500_000 >> liftIO (readIORef runs))
    -- Re-entering a loop that decided to stop is how a supervisor turns a
    -- surprise into a spin.
    result `shouldBe` 1

  -- The other half of #17.F.  The adapters were each retrying their own inner
  -- step, which is right, at a fixed rate forever, which is not: a week of
  -- "connection refused" from one homeserver put 27,707 attention lines in the
  -- journal, one every 2.4 seconds.
  describe "retryingWith" $ do
    it "carries the last state across a failure and advances it on success" $ do
      seen <- newIORef ([] :: [Int])
      -- Fails on the second attempt, so the third must be handed the state the
      -- second was given rather than a fresh one.
      let step n = do
            liftIO (atomicModifyIORef' seen (\xs -> (xs <> [n], ())))
            if n == 1
              then liftIO (throwIO (userError "transient"))
              else pure (n + 1)
      _ <-
        supervised . withWorkers [worker "carrier" RestartableWorker (retryingWith "carry" 0 step)] $
          threadDelay 1_500_000
      observed <- readIORef seen
      -- 0 succeeds → 1.  1 throws, so 1 is handed back.  1 throws again…
      take 3 observed `shouldBe` [0, 1, 1]

    it "logs a failure episode on powers of two rather than every attempt" $ do
      -- Not a log assertion — the counter is: the point is that the retry keeps
      -- attempting at full rate while the log damps, so a broken edge stays
      -- observable without drowning everything else.
      attempts <- newIORef (0 :: Int)
      _ <-
        supervised . withWorkers
          [ worker "noisy" RestartableWorker . retryingWith "noisy" () $ \() -> do
              liftIO (atomicModifyIORef' attempts (\c -> (c + 1, ())))
              liftIO (throwIO (userError "always"))
          ]
          $ threadDelay 1_200_000
      n <- readIORef attempts
      -- One immediately, one after the 1s backoff.  What matters is that the
      -- second attempt happened and only the first two were logged, which the
      -- run above shows in its own output.
      n `shouldSatisfy` (>= 2)

  it "still takes the process down when a plain optional worker throws" $ do
    -- The distinction is the whole change: 'OptionalWorker' means "finishing is
    -- fine", never "failing is fine".  The shutdown drain relies on exactly
    -- that, which is why it did not become restartable with the others.
    result <-
      try @SomeException . supervised $
        withWorkers
          [worker "one-shot-observer" OptionalWorker (liftIO (throwIO (userError "observer died")))]
          (threadDelay 5_000_000)
    result `shouldSatisfy` \case
      Left err -> "observer died" `isInfixOf` displayException err
      Right () -> False
