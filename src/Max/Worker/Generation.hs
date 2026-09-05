-- | Transactional lifecycle for reloadable worker generations.
--
-- A candidate's fallible preparation runs before its worker thread exists.
-- The prepared thread then waits behind a gate.  'commitGeneration' opens
-- that gate in the same STM transaction that publishes configuration, swaps
-- supervisor ownership, and only then retires the old generation.  Abandoned
-- candidates are cancellable without touching the active generation.
module Max.Worker.Generation
  ( GenerationSupervisor,
    PreparedGeneration,
    PrepareFailure (..),
    RetireOutcome (..),
    newGenerationSupervisor,
    closeGenerationSupervisor,
    prepareGeneration,
    abortGeneration,
    commitGeneration,
    activeWorkerGeneration,
  )
where

import Control.Concurrent.Async
  ( Async,
    async,
    asyncThreadId,
    cancel,
    link,
    waitCatch,
  )
import Control.Concurrent.MVar
  ( MVar,
    modifyMVar,
    modifyMVar_,
    newMVar,
    readMVar,
  )
import Control.Concurrent.STM
  ( STM,
    TMVar,
    atomically,
    newEmptyTMVarIO,
    putTMVar,
    readTMVar,
  )
import Control.Exception (finally, mask, onException)
import Control.Monad (void)
import Data.Word (Word64)
import Max.Util (trySyncIO)
import System.Timeout (timeout)

data ActiveGeneration = ActiveGeneration
  { agNumber :: !Word64,
    agWorker :: !(Async ())
  }

data GenerationSupervisor = GenerationSupervisor
  { gsActive :: !(MVar ActiveGeneration),
    -- | Workers which accepted cancellation but did not finish before the
    -- bounded handoff deadline.  A reaper removes each handle when it really
    -- exits; shutdown retries cancellation for anything still present.
    gsRetired :: !(MVar [Async ()])
  }

data PreparedGeneration = PreparedGeneration
  { pgNumber :: !Word64,
    pgGate :: !(TMVar ()),
    pgWorker :: !(Async ())
  }

data PrepareFailure = PrepareFailure
  deriving stock (Show, Eq)

data RetireOutcome
  = Retired
  | RetireTimedOut
  deriving stock (Show, Eq)

-- | Start and link generation 1 (or another caller-supplied initial number).
newGenerationSupervisor :: Word64 -> IO () -> IO GenerationSupervisor
newGenerationSupervisor generation action = do
  running <- async action
  link running
  GenerationSupervisor
    <$> newMVar (ActiveGeneration generation running)
    <*> newMVar []

closeGenerationSupervisor :: GenerationSupervisor -> IO ()
closeGenerationSupervisor supervisor = do
  readMVar supervisor.gsActive >>= cancel . (.agWorker)
  readMVar supervisor.gsRetired >>= mapM_ cancel

activeWorkerGeneration :: GenerationSupervisor -> IO Word64
activeWorkerGeneration supervisor = (.agNumber) <$> readMVar supervisor.gsActive

-- | Run all candidate-specific allocation/preflight before returning a
-- start-gated worker.  Exception details deliberately do not escape this API:
-- callers can report a stable category without accidentally logging secrets.
prepareGeneration :: Word64 -> IO (IO ()) -> IO (Either PrepareFailure PreparedGeneration)
prepareGeneration generation prepare = mask $ \restore -> do
  prepared <- trySyncIO (restore prepare)
  case prepared of
    Left _ -> pure (Left PrepareFailure)
    Right action -> do
      gate <- newEmptyTMVarIO
      running <- async (atomically (readTMVar gate) >> action)
      -- Re-open the async-exception window before ownership leaves this
      -- function.  If cancellation was deferred while allocating the worker,
      -- the finalizer prevents an unreachable start-gated thread.
      restore (pure (Right (PreparedGeneration generation gate running)))
        `onException` cancel running

abortGeneration :: PreparedGeneration -> IO ()
abortGeneration = cancel . (.pgWorker)

-- | Publish and activate together, then retire the old owner.  The supplied
-- STM action is the configuration commit point; if it throws/retries, the gate
-- remains closed and the prepared generation is cancelled.
commitGeneration ::
  GenerationSupervisor ->
  PreparedGeneration ->
  STM a ->
  IO (a, RetireOutcome)
commitGeneration supervisor prepared publish =
  mask $ \restore -> do
    link prepared.pgWorker
    result <-
      atomically (publish <* putTMVar prepared.pgGate ())
        `onException` abortGeneration prepared
    old <-
      modifyMVar supervisor.gsActive $ \current ->
        pure
          ( ActiveGeneration prepared.pgNumber prepared.pgWorker,
            current
          )
    retired <-
      timeout retireTimeoutMicros (restore (cancel old.agWorker))
        `onException` rememberRetired supervisor old.agWorker
    case retired of
      Just () -> pure (result, Retired)
      Nothing -> do
        rememberRetired supervisor old.agWorker
        pure (result, RetireTimedOut)

rememberRetired :: GenerationSupervisor -> Async () -> IO ()
rememberRetired supervisor worker = do
  modifyMVar_ supervisor.gsRetired (pure . (worker :))
  void . async $
    void (waitCatch worker)
      `finally` modifyMVar_ supervisor.gsRetired (pure . filter ((/= asyncThreadId worker) . asyncThreadId))

retireTimeoutMicros :: Int
retireTimeoutMicros = 5 * 1_000_000
