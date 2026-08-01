module Max.WorkerSpec (spec) where

import Control.Exception (SomeException, displayException, try)
import Data.List (isInfixOf)
import Effectful (runEff)
import Effectful.Concurrent (threadDelay)
import Effectful.Concurrent.Async (runConcurrent)
import Max.Worker
  ( WorkerCriticality (..),
    withWorkers,
    worker,
  )
import Test.Hspec

spec :: Spec
spec = describe "worker supervision" $ do
  it "fails with the worker name when a required worker returns normally" $ do
    result <-
      try @SomeException . runEff . runConcurrent $
        withWorkers
          [worker "event-ingest" RequiredWorker (pure ())]
          (threadDelay 5_000_000)
    result `shouldSatisfy` \case
      Left err -> "required worker exited normally: event-ingest" `isInfixOf` displayException err
      Right () -> False

  it "allows an enabled non-critical worker to finish" $ do
    result <-
      runEff . runConcurrent $
        withWorkers
          [worker "one-shot-observer" OptionalWorker (pure ())]
          (pure True)
    result `shouldBe` True
