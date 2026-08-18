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
  )
where

import Control.Exception (Exception (..), SomeException)
import Data.Aeson (object, (.=))
import Data.Text (Text)
import Data.Text qualified as T
import Effectful (Eff, IOE, liftIO, (:>))
import Effectful.Concurrent (Concurrent, threadDelay)
import Effectful.Concurrent.Async (link, withAsync)
import Effectful.Exception (throwIO)
import Effectful.Log (Log, logAttention)
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
