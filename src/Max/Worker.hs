-- | Scoped worker lifetimes and explicit retries for recoverable reads.
module Max.Worker
  ( Worker,
    WorkerCriticality (..),
    WorkerExited (..),
    worker,
    withWorkers,
    retrying,
  )
where

import Control.Concurrent qualified as Concurrent
import Control.Exception (Exception (..))
import Control.Monad (when)
import Data.Aeson (object, (.=))
import Data.Bits (popCount)
import Data.Text (Text)
import Data.Text qualified as T
import Effectful (Eff, IOE, liftIO, (:>))
import Effectful.Concurrent (Concurrent)
import Effectful.Concurrent.Async (link, withAsync)
import Effectful.Exception (throwIO)
import Effectful.Log (Log, logAttention, logInfo)

data WorkerCriticality
  = -- | A permanent service: returning means the process is degraded.
    RequiredWorker
  | -- | A supervised action whose clean completion is part of its contract.
    -- Exceptions are still linked and terminate the parent.
    OptionalWorker
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

-- | Link workers to the parent. Failure cancels the whole scope; a permanent
-- service returning normally is also a failure.
withWorkers :: (Concurrent :> es) => [Worker es] -> Eff es a -> Eff es a
withWorkers workers act = foldr supervise act workers
  where
    supervise spec rest = withAsync (run spec) $ \a -> link a >> rest
    run spec = do
      spec.workerAction
      case spec.workerCriticality of
        RequiredWorker -> throwIO (WorkerExited spec.workerName)
        OptionalWorker -> pure ()

-- | Retry only an explicit recoverable failure. The caller owns the read and
-- its cursor/state; exceptions and cancellation escape without replay.
retrying :: (Log :> es, IOE :> es) => Text -> Eff es (Either Text a) -> Eff es a
retrying label action = go (0 :: Int) 1
  where
    go failures delay =
      action >>= \case
        Right result -> do
          when (failures > 0) $
            logInfo (label <> ": recovered") $
              object ["after_consecutive_failures" .= failures]
          pure result
        Left err -> do
          let n = failures + 1
          -- Log attempts 1, 2, 4, 8, ... during a prolonged outage.
          when (popCount n == 1) $
            logAttention (label <> ": failed; retrying") $
              object
                [ "consecutive_failures" .= n,
                  "retry_in_seconds" .= delay,
                  "error" .= err
                ]
          liftIO (Concurrent.threadDelay (delay * 1_000_000))
          go n (min 60 (delay * 2))
