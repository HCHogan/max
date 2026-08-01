-- |
-- Supervision for the process's long-lived workers.  Config-disabled optional
-- workers are omitted by the caller; an enabled worker records whether a
-- clean return is meaningful or indicates that a critical service vanished.
module Max.Worker
  ( Worker,
    WorkerCriticality (..),
    WorkerExited (..),
    worker,
    withWorkers,
  )
where

import Control.Exception (Exception (..))
import Data.Text (Text)
import Data.Text qualified as T
import Effectful (Eff, (:>))
import Effectful.Concurrent.Async (Concurrent, link, withAsync)
import Effectful.Exception (throwIO)

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

-- | Run an action with every worker linked to it.  Worker exceptions retain
-- async's normal linked-exception propagation.  A required worker is wrapped
-- so even a normal return becomes an actionable supervisor failure.
withWorkers :: (Concurrent :> es) => [Worker es] -> Eff es a -> Eff es a
withWorkers workers act = foldr supervise act workers
  where
    supervise spec rest = withAsync (guardNormalExit spec) $ \a -> link a >> rest

    guardNormalExit spec = do
      _ <- spec.workerAction
      case spec.workerCriticality of
        RequiredWorker -> throwIO (WorkerExited spec.workerName)
        OptionalWorker -> pure ()
