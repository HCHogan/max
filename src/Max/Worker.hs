-- | Scoped supervision for long-lived workers. Required workers must not
-- return; optional workers may finish but still propagate exceptions.
-- Restartable workers retry synchronous failures with bounded backoff.
-- Async cancellation always propagates.
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
  | -- | Retry synchronous failures indefinitely with capped backoff.
    -- A run lasting at least the maximum delay resets it. Normal return is
    -- logged without restart; async cancellation propagates.
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

-- | Initial and maximum retry delays. A run lasting the maximum resets backoff.
initialBackoffSeconds, maxBackoffSeconds :: Int
initialBackoffSeconds = 1
maxBackoffSeconds = 60

-- | Link scoped workers to the parent. Required workers fail on normal return;
-- restartable workers catch only synchronous failures, preserving cancellation.
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
        -- Normal return is not retried under this worker policy.
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

-- | Repeat a step, preserving its previous state on synchronous failure.
-- Backoff resets after a successful step. Log the first failure, powers of two,
-- and recovery; async exceptions propagate. Unlike restarting the whole worker,
-- retrying a step retains the state from its last successful iteration.
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
