-- |
-- Supervision for the process's long-lived workers.  Config-disabled optional
-- workers are omitted by the caller; an enabled worker records whether a
-- clean return is meaningful or indicates that a critical service vanished.
--
-- __Every worker is linked, so an exception anywhere here ends the process.__
-- That is right for the services max cannot run without and wrong for the
-- optional edges, which is a distinction this module did not draw and each
-- worker therefore had to draw for itself — by never throwing.  Forgetting once
-- cost an outage, recorded where it happened in "Max.IMessage": a health check
-- sitting outside its own @catchSync@ meant a sleeping Mac
--
-- > took QQ, Matrix, the historian and every other worker down with it — then
-- > again ninety seconds later, for as long as the bridge stayed away.
--
-- 'RestartableWorker' is that distinction, drawn once.
module Max.Worker
  ( Worker,
    WorkerCriticality (..),
    WorkerExited (..),
    worker,
    withWorkers,
    retryingWith,
  )
where

import Control.Concurrent qualified as Concurrent
import Control.Exception (Exception (..), SomeException)
import Control.Monad (when)
import Data.Aeson (object, (.=))
import Data.Bits (popCount)
import Data.Text (Text)
import Data.Text qualified as T
import Effectful (Eff, IOE, liftIO, (:>))
import Effectful.Concurrent (Concurrent, threadDelay)
import Effectful.Concurrent.Async (link, withAsync)
import Effectful.Exception (throwIO)
import Effectful.Log (Log, logAttention, logInfo)
import GHC.Clock (getMonotonicTime)
import Max.Util (trySync)

data WorkerCriticality
  = -- | A permanent service: returning means the process is degraded.
    RequiredWorker
  | -- | A supervised action whose clean completion is part of its contract.
    -- Exceptions are still linked and terminate the parent.
    OptionalWorker
  | -- | An optional edge whose failure is an ordinary fact about the world —
    -- a bridge that went away, a homeserver returning 504 — and not a reason
    -- to take the process down.  Restarted after a backoff, forever.
    --
    -- __Forever, and deliberately not with a restart-intensity cap.__ The
    -- Erlang shape (give up after N restarts in T seconds) exists to stop a
    -- broken child from spinning, and here "give up" can only mean rethrow,
    -- which is exactly the outage being fixed: a permanently unreachable
    -- optional platform would kill the process on a timer, forever.  What the
    -- cap is really for — telling a crash loop apart from a worker that ran
    -- fine for a day and then broke — is in the backoff instead, which resets
    -- only after a run outlasts the longest wait.  A crash loop is then
    -- visible as a delay that climbs to the ceiling and stays, one attention
    -- log per minute, rather than as a silence.
    RestartableWorker
  deriving stock (Show, Eq)

data Worker es = Worker
  { workerName :: !Text,
    workerCriticality :: !WorkerCriticality,
    workerAction :: Eff es ()
  }

worker :: Text -> WorkerCriticality -> Eff es () -> Worker es
worker = Worker

newtype WorkerExited = WorkerExited {exitedWorkerName :: Text}
  deriving stock (Eq)

instance Show WorkerExited where
  show (WorkerExited name) =
    "required worker exited normally: " <> T.unpack name

instance Exception WorkerExited where
  displayException = show

-- | The first wait after a failure, and the ceiling it doubles toward.
--
-- The ceiling is also the bar a run has to clear before the wait resets: a
-- worker that stayed up longer than the longest backoff was working and then
-- broke, which is a different event from one that has never managed to start.
initialBackoffSeconds, maxBackoffSeconds :: Int
initialBackoffSeconds = 1
maxBackoffSeconds = 60

-- | Run an action with every worker linked to it.  Worker exceptions retain
-- async's normal linked-exception propagation.  A required worker is wrapped
-- so even a normal return becomes an actionable supervisor failure.
--
-- A 'RestartableWorker' is the exception to the linking, and only for
-- /synchronous/ failure: 'trySync' rethrows async exceptions, so a shutdown
-- still reaches it and still ends it.
withWorkers :: (Concurrent :> es, Log :> es, IOE :> es) => [Worker es] -> Eff es a -> Eff es a
withWorkers workers act = foldr supervise act workers
  where
    supervise spec rest = withAsync (run spec) $ \a -> link a >> rest

    run spec = case spec.workerCriticality of
      RestartableWorker -> restarting spec initialBackoffSeconds
      _ -> guardNormalExit spec

    guardNormalExit spec = do
      _ <- spec.workerAction
      case spec.workerCriticality of
        RequiredWorker -> throwIO (WorkerExited spec.workerName)
        OptionalWorker -> pure ()
        RestartableWorker -> pure ()

    restarting spec delay = do
      startedAt <- liftIO getMonotonicTime
      outcome <- trySync spec.workerAction
      case outcome of
        -- Not restarted.  These workers are loops, so returning is a surprise
        -- rather than a completion, and re-entering one that decided to stop
        -- is how a supervisor turns a surprise into a spin.
        Right () ->
          logAttention "worker returned and will not be restarted" $
            object ["worker" .= spec.workerName]
        Left e -> do
          ranFor <- subtract startedAt <$> liftIO getMonotonicTime
          let wait
                | ranFor >= fromIntegral maxBackoffSeconds = initialBackoffSeconds
                | otherwise = delay
          logAttention "worker failed; restarting after backoff" $
            object
              [ "worker" .= spec.workerName,
                "error" .= T.pack (show (e :: SomeException)),
                "ran_for_seconds" .= (round ranFor :: Int),
                "restart_in_seconds" .= wait
              ]
          threadDelay (wait * 1_000_000)
          restarting spec (min maxBackoffSeconds (wait * 2))

-- | Repeat a step forever, carrying its state across failures.
--
-- The inner half of the same idea 'RestartableWorker' is the outer half of, and
-- the two are different jobs rather than one written twice.  A restart is total
-- — it re-registers the endpoint, refetches the roster, and starts the poll
-- from a cold cache — which is the right answer to a worker that has stopped
-- making sense and much too heavy an answer to a homeserver that refused one
-- connection.  So the step keeps whatever it had: on failure the /previous/
-- state is handed to the next attempt, which is exactly what each adapter's
-- own loop was doing by hand.
--
-- What they were not doing is the two things below, and the second is why this
-- exists at all.
--
-- __It backs off, and success resets it.__  Every adapter retried at a fixed
-- rate forever: two seconds for Matrix, the poll interval for iMessage.  Here
-- the wait doubles to a ceiling and drops back the moment a step returns — a
-- step returning /is/ the recovery signal, which the supervisor cannot see and
-- has to approximate with a clock.
--
-- __It logs an episode, not an attempt.__  A week of @Connection refused@ from
-- one homeserver put 27,707 attention lines in the journal, one every 2.4
-- seconds, which is not a report of an outage so much as a denial of service
-- against everything else in the log.  A failure is logged on the first
-- attempt and then only when the count reaches a power of two, so a sustained
-- outage costs about a dozen lines a week and still says "yes, still broken"
-- often enough to be believed.  Recovery is one more line, with the count.
retryingWith ::
  (Log :> es, IOE :> es) =>
  -- | What is being retried, for the log.
  Text ->
  -- | Starting state.
  s ->
  -- | One attempt.  Its result becomes the next attempt's state; a throw
  -- leaves the state untouched.
  (s -> Eff es s) ->
  Eff es ()
retryingWith label start step = go (0 :: Int) initialBackoffSeconds start
  where
    go failures delay state =
      trySync (step state) >>= \case
        Right next -> do
          when (failures > 0) $
            logInfo (label <> ": recovered") $
              object ["after_consecutive_failures" .= failures]
          go 0 initialBackoffSeconds next
        Left e -> do
          let n = failures + 1
          -- 1, 2, 4, 8, … — dense enough at the start to catch a real
          -- incident, sparse enough afterwards that a broken edge cannot
          -- bury everything else.
          when (popCount n == 1) $
            logAttention (label <> ": failed; retrying") $
              object
                [ "consecutive_failures" .= n,
                  "retry_in_seconds" .= delay,
                  "error" .= T.pack (show (e :: SomeException))
                ]
          liftIO (Concurrent.threadDelay (delay * 1_000_000))
          go n (min maxBackoffSeconds (delay * 2)) state
