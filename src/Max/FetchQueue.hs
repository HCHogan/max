-- | Wakeup signal and shared loop for the durable media fetch queue.
-- Jobs live in Max.DB.FetchQueue; enqueueing signals workers immediately.
-- Waits are bounded so expired leases are rechecked without an enqueue event.
module Max.FetchQueue
  ( FetchSignal,
    newFetchSignal,
    notifyFetch,
    runFetchLoop,
  )
where

import Control.Concurrent.STM
  ( TVar,
    atomically,
    modifyTVar',
    newTVarIO,
    readTVar,
    readTVarIO,
    registerDelay,
    retry,
  )
import Control.Monad (unless)
import Data.Aeson (FromJSON)
import Data.Text (Text)
import Data.Text qualified as T
import Effectful
import Effectful.Concurrent (Concurrent)
import Effectful.Log
import Effectful.PostgreSQL (WithConnection)
import Max.Concurrent.Lease
import Max.DB.FetchQueue
  ( ClaimedJob (..),
    JobKind,
    claimJobs,
    completeJob,
    failJob,
    jobClaim,
    renewJob,
  )
import Max.Util (trySync)

-- | \"Something was queued\" bell — a monotonically bumped counter,
-- holding no job data of its own.
newtype FetchSignal = FetchSignal {fsTick :: TVar Int}

newFetchSignal :: IO FetchSignal
newFetchSignal = FetchSignal <$> newTVarIO 0

-- | Wake the workers.  Call after 'Max.DB.FetchQueue.enqueueJob'; a
-- missed bump costs latency (until the next bounded re-check), never
-- correctness.
notifyFetch :: FetchSignal -> IO ()
notifyFetch s = atomically (modifyTVar' s.fsTick (+ 1))

-- | Longest a worker sleeps before re-checking the queue unprompted.
-- Not a poll interval — fresh work always wakes it immediately; this
-- only bounds how long an expired lease can sit unnoticed.
recheckMicros :: Int
recheckMicros = 60 * 1000000

-- | Claim and process jobs, waiting on the signal when none are ready.
-- Both Left results and synchronous exceptions go through failJob, which
-- decides whether to retry or park the job.
runFetchLoop ::
  (Concurrent :> es, WithConnection :> es, Log :> es, IOE :> es, FromJSON a) =>
  FetchSignal ->
  JobKind ->
  -- | Lease length; comfortably longer than the slowest fetch of this kind.
  Int ->
  -- | How many jobs to take per claim.
  Int ->
  (a -> Eff es (Either Text ())) ->
  Eff es ()
runFetchLoop signal kind leaseSeconds batch process = loop
  where
    loop = do
      -- Snapshot the tick *before* claiming, same reasoning as
      -- 'Max.Monitor.monitorWorker': an enqueue landing between the
      -- claim and the sleep must still wake us, and it won't match.
      v0 <- liftIO (readTVarIO signal.fsTick)
      jobs <- claimJobs kind leaseSeconds batch
      if null jobs
        then liftIO (waitTick v0) >> loop
        else mapM_ one jobs >> loop

    waitTick v0 = do
      timer <- registerDelay recheckMicros
      atomically $ do
        v <- readTVar signal.fsTick
        fired <- readTVar timer
        unless (fired || v /= v0) retry

    one j = do
      result <- withOwnedLease
        (max 1 (leaseSeconds `div` 3) * 1_000_000)
        (renewJob (jobClaim j) leaseSeconds)
        $ do
          held <- renewJob (jobClaim j) leaseSeconds
          if not held
            then pure ()
            else do
              r <- trySync (process j.cjPayload)
              case r of
                Right (Right ()) -> completeJob (jobClaim j)
                Right (Left err) -> giveBack j err
                Left e -> giveBack j (T.pack (show e))
      case result of
        LeaseCompleted () -> pure ()
        LeaseLost -> logAttention "fetch lease lost; stale worker stopped" $ object ["id" .= j.cjId]

    giveBack j err = do
      logAttention "fetch job failed" $
        object
          [ "kind" .= T.pack (show kind),
            "id" .= j.cjId,
            "attempt" .= j.cjAttempt,
            "error" .= err
          ]
      failJob (jobClaim j) err
