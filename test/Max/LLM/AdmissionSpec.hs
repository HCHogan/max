module Max.LLM.AdmissionSpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async qualified as Async
import Control.Concurrent.MVar
import Control.Exception (bracket)
import Control.Monad (forM, forM_, void)
import Data.IORef
import Data.Text (Text)
import Effectful
import Max.LLM.Admission
import System.Timeout (timeout)
import Test.Hspec

spec :: Spec
spec = describe "provider admission" $ do
  it "classifies frontend calls separately from background task calls" $ do
    priorityForSource "turn" `shouldBe` Interactive
    priorityForSource "task/turn" `shouldBe` Background
    priorityForSource "historian" `shouldBe` Background

  it "reserves foreground capacity while background calls are saturated" $ do
    admission <- newAdmission 2 1
    release <- newEmptyMVar
    Async.withAsync (run admission "provider" Background (takeMVar release)) $ \_ -> do
      awaitCounts admission "provider" (1, 0)
      Async.withAsync (run admission "provider" Background (pure ())) $ \waiting -> do
        awaitCounts admission "provider" (1, 1)
        timeout 1000000 (run admission "provider" Interactive (pure ())) `shouldReturn` Just ()
        admissionCounts admission "provider" `shouldReturn` (1, 1)
        putMVar release ()
        Async.wait waiting
    awaitCounts admission "provider" (0, 0)

  it "serves waiting foreground first but gives background a turn after five admissions" $ do
    admission <- newAdmission 1 0
    release <- newEmptyMVar
    order <- newIORef ([] :: [Text])
    let record label = atomicModifyIORef' order (\previous -> (previous <> [label], ()))
    Async.withAsync (run admission "provider" Background (takeMVar release)) $ \_ -> do
      awaitCounts admission "provider" (1, 0)
      Async.withAsync (run admission "provider" Background (record "background")) $ \background -> do
        awaitCounts admission "provider" (1, 1)
        bracket
          ( forM [1 .. 6 :: Int] $ \index -> do
              worker <- Async.async (run admission "provider" Interactive (record "foreground"))
              awaitCounts admission "provider" (1, index + 1)
              pure worker
          )
          (mapM_ Async.cancel)
          $ \frontends -> do
            putMVar release ()
            mapM_ Async.wait frontends
            Async.wait background
    readIORef order `shouldReturn` (replicate 5 "foreground" <> ["background", "foreground"])

  it "does not leak queued or active capacity on cancellation" $ do
    admission <- newAdmission 1 0
    never <- newEmptyMVar
    Async.withAsync (run admission "provider" Background (takeMVar never)) $ \active -> do
      awaitCounts admission "provider" (1, 0)
      Async.withAsync (run admission "provider" Interactive (pure ())) $ \queued -> do
        awaitCounts admission "provider" (1, 1)
        Async.cancel queued
        awaitCounts admission "provider" (1, 0)
      Async.cancel active
    awaitCounts admission "provider" (0, 0)

  it "keeps providers independent" $ do
    admission <- newAdmission 1 0
    never <- newEmptyMVar
    Async.withAsync (run admission "first" Background (takeMVar never)) $ \_ -> do
      awaitCounts admission "first" (1, 0)
      timeout 1000000 (run admission "second" Background (pure ())) `shouldReturn` Just ()

  forM_ [(0, 0), (2, 2), (2, -1)] $ \(capacity, reserved) ->
    it ("rejects invalid capacity " <> show (capacity, reserved)) $
      void (newAdmission capacity reserved) `shouldThrow` anyIOException

run :: Admission -> Text -> Priority -> IO value -> IO value
run admission provider priority action =
  runEff (withAdmission admission provider priority (liftIO action))

awaitCounts :: Admission -> Text -> (Int, Int) -> IO ()
awaitCounts admission provider expected = do
  let poll = do
        actual <- admissionCounts admission provider
        if actual == expected then pure () else threadDelay 1000 >> poll
  timeout 2000000 poll `shouldReturn` Just ()
