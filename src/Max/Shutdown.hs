-- | Bounded graceful shutdown for agent dispatches. Admission and the drain
-- flag share an STM transaction; each dispatch holds a slot from entry through
-- context collection, execution and finalization. Other background queues use
-- their existing persistent recovery paths.
-- QQ reconnect backfill is bounded and deduplicated, not a complete offline
-- cursor: messages outside its windows, reactions and recalls may be missed.
module Max.Shutdown
  ( ShutdownState,
    newShutdownState,

    -- * Dispatch side
    enterDispatch,
    leaveDispatch,
    enterDispatchWith,
    leaveDispatchWith,

    -- * Shutdown side
    beginDrain,
    awaitDrain,
    inflightCount,
    awaitQuiescent,
    drainWorker,
  )
where

import Control.Concurrent (ThreadId)
import Control.Concurrent.STM
  ( STM,
    TVar,
    atomically,
    modifyTVar',
    newTVarIO,
    readTVar,
    readTVarIO,
    registerDelay,
    retry,
    writeTVar,
  )
import Control.Exception (AsyncException (UserInterrupt), throwTo)
import Control.Monad (unless)
import Data.Maybe (isJust)
import Data.Ord (clamp)
import Effectful
import Effectful.Log

-- | Process-wide shutdown state.  Holds no dispatch data itself — just
-- the gate and a count of what's still running.
data ShutdownState = ShutdownState
  { ssDraining :: !(TVar Bool),
    ssInflight :: !(TVar Int)
  }

newShutdownState :: IO ShutdownState
newShutdownState = ShutdownState <$> newTVarIO False <*> newTVarIO 0

--------------------------------------------------------------------------------
-- Dispatch side

-- | Claim an in-flight slot.  'False' means we're draining and the
-- caller must not start.  The check and the increment share one
-- transaction, so a dispatch can never slip past the gate and then be
-- missed by 'awaitQuiescent'.
enterDispatch :: ShutdownState -> IO Bool
enterDispatch st = isJust <$> enterDispatchWith st (pure ())

-- | Atomically claim a dispatch slot and acquire another process-local
-- resource, such as the current configuration generation.  Keeping these in
-- one transaction gives reload and shutdown one precise admission boundary.
enterDispatchWith :: ShutdownState -> STM a -> IO (Maybe a)
enterDispatchWith st acquire = atomically $ do
  draining <- readTVar st.ssDraining
  if draining
    then pure Nothing
    else do
      value <- acquire
      modifyTVar' st.ssInflight (+ 1)
      pure (Just value)

-- | Release a slot claimed by 'enterDispatch'.  Belongs in a @finally@
-- — a dispatch that died without releasing would hold shutdown
-- hostage until the drain deadline.
leaveDispatch :: ShutdownState -> IO ()
leaveDispatch st = leaveDispatchWith st (pure ())

-- | Release an associated resource and the shutdown slot in the same STM
-- transaction.  The caller still owns the usual outer @finally@ obligation.
leaveDispatchWith :: ShutdownState -> STM () -> IO ()
leaveDispatchWith st release = atomically $ do
  release
  modifyTVar' st.ssInflight (subtract 1)

--------------------------------------------------------------------------------
-- Shutdown side

-- | Flip into draining mode.  'True' when this call is what flipped
-- it; 'False' means a drain was already under way — which is how the
-- signal handler tells a second SIGTERM (\"I said now\") from the
-- first.
beginDrain :: ShutdownState -> IO Bool
beginDrain st = atomically $ do
  draining <- readTVar st.ssDraining
  if draining
    then pure False
    else True <$ writeTVar st.ssDraining True

-- | Block until 'beginDrain' fires.  Lets the drain supervisor live as
-- an ordinary worker (and so log through the effect stack) while the
-- signal handler itself stays trivial and non-blocking.
awaitDrain :: ShutdownState -> IO ()
awaitDrain st = atomically $ do
  draining <- readTVar st.ssDraining
  unless draining retry

inflightCount :: ShutdownState -> IO Int
inflightCount st = readTVarIO st.ssInflight

-- | Block until nothing is in flight, or @seconds@ elapse.  Returns
-- how many dispatches were still running when it gave up — @0@ is a
-- clean drain.  Same @registerDelay@ + 'retry' idiom as
-- 'Max.Monitor.monitorWorker': the wait ends the instant the last
-- dispatch releases its slot, no polling.
awaitQuiescent :: Int -> ShutdownState -> IO Int
awaitQuiescent seconds st = do
  timer <- registerDelay (delayMicros seconds)
  atomically $ do
    n <- readTVar st.ssInflight
    if n == 0
      then pure 0
      else do
        expired <- readTVar timer
        if expired then pure n else retry

-- | Seconds to microseconds, clamped to @[0, 1h]@ so a fat-fingered
-- config value can't overflow the 'Int' 'registerDelay' takes.
delayMicros :: Int -> Int
delayMicros s = clamp (0, 3600) s * 1_000_000

--------------------------------------------------------------------------------
-- Supervisor

-- | Wait for beginDrain, then for dispatch completion or the drain deadline.
-- Raise UserInterrupt on the main thread so its brackets release resources.
-- The signal handler only changes state; waiting and logging happen here.
drainWorker ::
  (Log :> es, IOE :> es) =>
  -- | How long to wait for in-flight dispatches ('AppConfig.shutdownDrainSeconds').
  Int ->
  -- | Main thread, to interrupt once drained.
  ThreadId ->
  ShutdownState ->
  Eff es ()
drainWorker seconds mainTid st = localDomain "shutdown" $ do
  liftIO (awaitDrain st)
  n0 <- liftIO (inflightCount st)
  logInfo "draining: taking no new dispatches" $
    object ["in_flight" .= n0, "timeout_s" .= seconds]
  left <- liftIO (awaitQuiescent seconds st)
  if left == 0
    then logInfo_ "drained: all dispatches finished"
    else
      logAttention "drain timed out; abandoning dispatches" $
        object ["in_flight" .= left]
  liftIO (throwTo mainTid UserInterrupt)
