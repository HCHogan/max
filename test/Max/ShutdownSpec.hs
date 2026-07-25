-- |
-- The drain path only runs on SIGTERM, so production exercises it once
-- per deploy and never notices if it rots.  These cover the two things
-- that would silently break it: the gate/counter race, and
-- 'awaitQuiescent' degrading into a plain sleep.
module Max.ShutdownSpec (spec) where

import Control.Concurrent (forkIO, threadDelay)
import Max.Shutdown
  ( awaitQuiescent,
    beginDrain,
    enterDispatch,
    inflightCount,
    leaveDispatch,
    newShutdownState,
  )
import System.Timeout (timeout)
import Test.Hspec

spec :: Spec
spec = describe "Max.Shutdown" $ do
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
    left <- awaitQuiescent 3600 st
    left `shouldBe` 0

  it "reports what was still running when the deadline passes" $ do
    st <- newShutdownState
    _ <- enterDispatch st
    _ <- enterDispatch st
    left <- awaitQuiescent 0 st
    left `shouldBe` 2

  -- The point of the STM 'retry': a drain must end the instant the
  -- last dispatch releases, not when its (generous) deadline expires.
  -- With a polling or sleeping implementation this times out.
  it "wakes as soon as the last dispatch leaves, not at the deadline" $ do
    st <- newShutdownState
    _ <- enterDispatch st
    _ <- forkIO (threadDelay 50_000 >> leaveDispatch st)
    r <- timeout 5_000_000 (awaitQuiescent 3600 st)
    r `shouldBe` Just 0
