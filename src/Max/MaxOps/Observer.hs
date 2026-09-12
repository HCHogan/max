-- | A wall-clock deadline is anchored once to a monotonic clock. Retries and
-- wall-clock adjustments cannot extend observation. Before learning the remote
-- deadline, use a two-minute window: from admission for writes, or from the
-- current recovery attempt for receipt reads. Both respect the task deadline.
module Max.MaxOps.Observer
  ( ObserverBudget,
    observerBudgetAt,
    newObserverBudget,
    withRemoteDeadline,
    remainingMicrosAt,
    withinBudget,
  )
where

import Data.Maybe (fromMaybe)
import Data.Time (UTCTime, addUTCTime, diffUTCTime, getCurrentTime)
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)
import System.Timeout (timeout)

data ObserverBudget = ObserverBudget
  { anchorTime :: !UTCTime,
    anchorTick :: !Word64,
    discoveryEnd :: !Integer,
    taskEnd :: !Integer,
    remoteEnd :: !(Maybe Integer)
  }

observerBudgetAt :: UTCTime -> Word64 -> UTCTime -> UTCTime -> ObserverBudget
observerBudgetAt now tick admitted taskDeadline =
  ObserverBudget now tick (at (addUTCTime 120 admitted)) (at (addUTCTime (-5) taskDeadline)) Nothing
  where
    at wall = toInteger tick + floor (diffUTCTime wall now * 1_000_000_000)

newObserverBudget :: UTCTime -> UTCTime -> IO ObserverBudget
newObserverBudget admitted deadline = do
  now <- getCurrentTime
  tick <- getMonotonicTimeNSec
  pure (observerBudgetAt now tick admitted deadline)

-- | The first remote deadline replaces the receipt-discovery window. Later
-- responses may shorten it, never extend it. Grace allows terminal persistence
-- and a bounded evidence fetch after the remote deadline.
withRemoteDeadline :: UTCTime -> ObserverBudget -> ObserverBudget
withRemoteDeadline deadline budget = budget {remoteEnd = Just (maybe end (min end) budget.remoteEnd)}
  where
    end = toInteger budget.anchorTick + floor (diffUTCTime (addUTCTime 30 deadline) budget.anchorTime * 1_000_000_000)

-- | Bound individual HTTP calls too, including a call straddling the cutoff.
remainingMicrosAt :: Word64 -> ObserverBudget -> Int
remainingMicrosAt tick budget = fromInteger (max 0 (min (toInteger (maxBound :: Int)) ((end - toInteger tick) `div` 1000)))
  where
    end = min budget.taskEnd (fromMaybe budget.discoveryEnd budget.remoteEnd)

withinBudget :: ObserverBudget -> IO a -> IO (Maybe a)
withinBudget budget action = do
  remaining <- (`remainingMicrosAt` budget) <$> getMonotonicTimeNSec
  if remaining == 0 then pure Nothing else timeout remaining action
