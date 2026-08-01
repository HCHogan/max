-- |
-- The in-memory half of the media fetch queue: a wakeup bell and the
-- loop all three media workers run.  The @fetch_jobs@ table
-- ("Max.DB.FetchQueue") is authoritative; this module holds no job
-- state at all, exactly like 'Max.Reminder.ReminderScheduler' next to
-- the @reminders@ table.
--
-- __Why a signal and not a poll.__  Media has to land fast — the
-- prompt builder blocks on the trigger's own images
-- ('Max.Prompt.waitForTriggerImages'), so a poll interval would show
-- up directly as latency before every picture reply.  Enqueueing bumps
-- the signal and the sleeping worker wakes at once.
--
-- __Why the sleep is still bounded.__  One thing genuinely has no
-- event to fire: a lease expiring.  If a process dies mid-fetch the
-- job stays claimed until its lease runs out, and nothing bumps the
-- signal at that moment.  Restarts are covered anyway (the first claim
-- runs before any sleep), so the cap only matters for a fetch that
-- outlives its own lease — rare enough that a lazy re-check is the
-- right price.
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
import Effectful.Log
import Effectful.PostgreSQL (WithConnection)
import Max.DB.FetchQueue
  ( ClaimedJob (..),
    JobKind,
    claimJobs,
    completeJob,
    failJob,
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

-- | Claim, process, repeat; sleep on the signal when the queue runs
-- dry.  Shared by the image pool, the forward worker and the file
-- worker — they differ only in what @process@ does.
--
-- The callback reports a retryable failure as @Left@; a thrown
-- synchronous exception is treated the same way.  Either way
-- 'Max.DB.FetchQueue.failJob' decides whether the job goes back in the
-- pool or parks.
runFetchLoop ::
  (WithConnection :> es, Log :> es, IOE :> es, FromJSON a) =>
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
      -- 'Max.Reminder.reminderWorker': an enqueue landing between the
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
      r <- trySync (process j.cjPayload)
      case r of
        Right (Right ()) -> completeJob j.cjId
        Right (Left err) -> giveBack j err
        Left e -> giveBack j (T.pack (show e))

    giveBack j err = do
      logAttention "fetch job failed" $
        object
          [ "kind" .= T.pack (show kind),
            "id" .= j.cjId,
            "attempt" .= j.cjAttempt,
            "error" .= err
          ]
      failJob j.cjId err
