-- |
-- The drain path only runs on SIGTERM, so production exercises it once
-- per deploy and never notices if it rots.  These cover the two things
-- that would silently break it: the gate/counter race, and
-- 'awaitQuiescent' degrading into a plain sleep.
module Max.ShutdownSpec (spec) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.Async (asyncThreadId, wait, withAsync)
import Effectful (liftIO, runEff)
import Effectful.Concurrent (runConcurrent)
import Effectful.Log (LogLevel (LogAttention), runLog)
import Max.Log (ColorMode (ColorNever), withCompactLogger)
import Max.Platform.Delivery.Queue
import Max.Platform.Store.Delivery
  ( DeliveryCompletion (..),
    DeliveryTarget (..),
  )
import Max.Platform.Types (DeliveryId (..), EndpointId (..), Platform (..))
import Max.Shutdown
  ( awaitQuiescent,
    beginDrain,
    drainWorker,
    enterDispatch,
    inflightCount,
    leaveDispatch,
    newShutdownState,
  )
import System.Timeout (timeout)
import Test.Hspec

spec :: Spec
spec = describe "Max.Shutdown" $ do
  it "shares one deadline between shutdown notices and remaining deliveries" $ do
    st <- newShutdownState
    deliveries <- newDeliveryQueue (DeliveryId 0)
    _ <- beginDrain st
    let target = DeliveryTarget (DeliveryId 1) (EndpointId 1) PlatformQQ
        notice = liftIO (threadDelay 600_000 >> queueDeliveries deliveries [target])
    withAsync (threadDelay 5_000_000) $ \mainThread ->
      withCompactLogger ColorNever Nothing $ \logger ->
        timeout
          1_400_000
          (runEff . runConcurrent . runLog "shutdown-test" logger LogAttention $ drainWorker 1 (asyncThreadId mainThread) st deliveries notice)
          `shouldReturn` Just ()

  it "admits dispatches and counts them while not draining" $ do
    st <- newShutdownState
    ok1 <- enterDispatch st
    ok2 <- enterDispatch st
    n <- inflightCount st
    (ok1, ok2, n) `shouldBe` (True, True, 2)

  it "refuses new dispatches once draining" $ do
    st <- newShutdownState
    _ <- beginDrain st
    ok <- enterDispatch st
    ok `shouldBe` False

  it "leaves the count untouched when it refuses" $ do
    st <- newShutdownState
    _ <- beginDrain st
    _ <- enterDispatch st
    n <- inflightCount st
    n `shouldBe` 0

  it "reports only the first beginDrain — that is the second-SIGTERM escape hatch" $ do
    st <- newShutdownState
    first <- beginDrain st
    second <- beginDrain st
    (first, second) `shouldBe` (True, False)

  it "quiesces immediately when nothing is in flight" $ do
    st <- newShutdownState
    deliveries <- newDeliveryQueue (DeliveryId 0)
    timeout 1_000_000 (awaitQuiescent st deliveries) `shouldReturn` Just ()

  it "does not report quiescence while a dispatch is still running" $ do
    st <- newShutdownState
    deliveries <- newDeliveryQueue (DeliveryId 0)
    _ <- enterDispatch st
    _ <- enterDispatch st
    timeout 20_000 (awaitQuiescent st deliveries) `shouldReturn` Nothing

  -- The point of the STM 'retry': a drain must end the instant the
  -- last dispatch releases, not when its (generous) deadline expires.
  -- With a polling or sleeping implementation this times out.
  it "wakes as soon as the last dispatch leaves, not at the deadline" $ do
    st <- newShutdownState
    deliveries <- newDeliveryQueue (DeliveryId 0)
    _ <- enterDispatch st
    _ <- forkIO (threadDelay 50_000 >> leaveDispatch st)
    r <- timeout 5_000_000 (awaitQuiescent st deliveries)
    r `shouldBe` Just ()

  it "waits for the last reply and every mirror after its dispatch has finished" $ do
    st <- newShutdownState
    deliveries <- newDeliveryQueue (DeliveryId 0)
    _ <- enterDispatch st
    let qq = DeliveryTarget (DeliveryId 1) (EndpointId 1) PlatformQQ
        matrix = DeliveryTarget (DeliveryId 2) (EndpointId 2) PlatformMatrix
    withAsync (awaitQuiescent st deliveries) $ \draining -> do
      queueDeliveries deliveries [qq, matrix]
      leaveDispatch st
      _ <- nextDelivery deliveries (== PlatformQQ)
      timeout 20_000 (wait draining) `shouldReturn` Nothing
      settleDelivery deliveries qq.deliveryId (DeliveryConfirmedAs Nothing)
      timeout 20_000 (wait draining) `shouldReturn` Nothing
      _ <- nextDelivery deliveries (== PlatformMatrix)
      timeout 20_000 (wait draining) `shouldReturn` Nothing
      settleDelivery deliveries matrix.deliveryId (DeliveryConfirmedAs Nothing)
      timeout 1_000_000 (wait draining) `shouldReturn` Just ()
