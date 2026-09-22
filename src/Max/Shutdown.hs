-- | Stop admission, then wait for running turns and queued output under one
-- deadline. Hard crashes do not replay work.
module Max.Shutdown
  ( ShutdownState,
    newShutdownState,

    -- * Dispatch side
    enterDispatch,
    leaveDispatch,

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
  ( TVar,
    atomically,
    check,
    modifyTVar',
    newTVarIO,
    readTVar,
    readTVarIO,
    retry,
    writeTVar,
  )
import Control.Exception (AsyncException (UserInterrupt), throwTo)
import Control.Monad (unless)
import Data.Ord (clamp)
import Effectful
import Effectful.Concurrent (Concurrent, threadDelay)
import Effectful.Concurrent.Async (race)
import Effectful.Log
import Max.Platform.Delivery.Queue (DeliveryQueue, pendingDeliveryCount)
import Max.Util (catchSync)

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
enterDispatch st = atomically $ do
  draining <- readTVar st.ssDraining
  if draining
    then pure False
    else do
      modifyTVar' st.ssInflight (+ 1)
      pure True

-- | Release a slot claimed by 'enterDispatch'.  Belongs in a @finally@
-- — a dispatch that died without releasing would hold shutdown
-- hostage until the drain deadline.
leaveDispatch :: ShutdownState -> IO ()
leaveDispatch st = atomically (modifyTVar' st.ssInflight (subtract 1))

--------------------------------------------------------------------------------
-- Shutdown side

-- | Return False for repeated signals so the caller can force shutdown.
beginDrain :: ShutdownState -> IO Bool
beginDrain st = atomically $ do
  draining <- readTVar st.ssDraining
  if draining
    then pure False
    else True <$ writeTVar st.ssDraining True

-- | Wait for the signal handler to request a drain; the handler never blocks.
awaitDrain :: ShutdownState -> IO ()
awaitDrain st = atomically $ do
  draining <- readTVar st.ssDraining
  unless draining retry

inflightCount :: ShutdownState -> IO Int
inflightCount st = readTVarIO st.ssInflight

-- | A finished turn may still own queued output. Observe both in one transaction.
awaitQuiescent :: ShutdownState -> DeliveryQueue -> IO ()
awaitQuiescent st deliveries = atomically $ do
  active <- readTVar st.ssInflight
  pending <- pendingDeliveryCount deliveries
  check (active == 0 && pending == 0)

-- | Seconds to microseconds, clamped to @[0, 1h]@ so a fat-fingered
-- config value can't overflow the 'Int' 'registerDelay' takes.
delayMicros :: Int -> Int
delayMicros s = clamp (0, 3600) s * 1_000_000

--------------------------------------------------------------------------------
-- Supervisor

-- | Notifications, dispatches and output share one shutdown deadline.
-- Raise UserInterrupt on the main thread so its brackets release resources.
-- The signal handler only changes state; waiting and logging happen here.
drainWorker ::
  (Log :> es, Concurrent :> es, IOE :> es) =>
  -- | How long to wait for in-flight dispatches ('AppConfig.shutdownDrainSeconds').
  Int ->
  -- | Main thread, to interrupt once drained.
  ThreadId ->
  ShutdownState ->
  DeliveryQueue ->
  Eff es () ->
  Eff es ()
drainWorker seconds mainTid st deliveries onDrain = localDomain "shutdown" $ do
  liftIO (awaitDrain st)
  n0 <- liftIO (inflightCount st)
  logInfo "draining: taking no new dispatches" $
    object ["in_flight" .= n0, "timeout_s" .= seconds]
  let notify = onDrain `catchSync` \err -> logAttention "shutdown notification failed" (object ["error" .= show err])
  outcome <- race (threadDelay (delayMicros seconds)) (notify >> liftIO (awaitQuiescent st deliveries))
  case outcome of
    Right () -> logInfo_ "drained: dispatches and deliveries finished"
    Left () -> do
      left <- liftIO (inflightCount st)
      pending <- liftIO (atomically (pendingDeliveryCount deliveries))
      logAttention "drain timed out; abandoning dispatches" $
        object ["in_flight" .= left, "pending_deliveries" .= pending]
  liftIO (throwTo mainTid UserInterrupt)
