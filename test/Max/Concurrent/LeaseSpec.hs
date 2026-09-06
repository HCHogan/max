module Max.Concurrent.LeaseSpec (spec) where

import Control.Concurrent.STM
import Effectful (liftIO, runEff)
import Effectful.Concurrent (runConcurrent)
import Effectful.Exception (finally)
import Max.Concurrent.Lease
import System.Timeout (timeout)
import Test.Hspec

spec :: Spec
spec = describe "owned lease lifecycle" $ do
  it "renews while work is alive and stops the renewer when it finishes" $ do
    ticks <- newTVarIO (0 :: Int)
    result <-
      timeout 1000000 $
        runEff . runConcurrent $
          withOwnedLease
            1000
            (liftIO (atomically (modifyTVar' ticks (+ 1))) >> pure True)
            (liftIO (atomically (readTVar ticks >>= \n -> check (n >= 2))) >> pure "done")
    result `shouldBe` Just (LeaseCompleted ("done" :: String))

  it "cancels and joins the action when renewal reports lost ownership" $ do
    started <- newEmptyTMVarIO
    stopped <- newTVarIO False
    result <-
      timeout 1000000 $
        runEff . runConcurrent $
          withOwnedLease
            1000
            (liftIO (atomically (readTMVar started)) >> pure False)
            ( (liftIO (atomically (putTMVar started ())) >> liftIO (atomically retry))
                `finally` liftIO (atomically (writeTVar stopped True))
            )
    result `shouldBe` Just (LeaseLost :: LeaseRun ())
    readTVarIO stopped `shouldReturn` True
