-- |
-- Graceful shutdown: on SIGTERM, stop starting new agent dispatches,
-- let the ones already running finish, /then/ die.
--
-- __Why a counter and not the task registry.__  "Max.Tasks" only sees
-- a dispatch once 'Max.Effects.Agent.agentTurn' brackets it, and
-- 'Max.Handler.dispatchLLM' does a lot before reaching that point —
-- session load, the supplement classifier's own LLM round-trip, and
-- 'Max.Prompt.buildContext', which by itself waits up to 30s for the
-- trigger's images to land.  Draining on @listTasks@ would walk right
-- past a dispatch sitting in that window.  So the slot is claimed at
-- dispatch /entry/ instead, and released by a @finally@ wrapping the
-- whole async.
--
-- __Why only agent dispatches.__  Everything else an abrupt exit could
-- interrupt is already DB-authoritative and picks itself back up:
-- inbound media ("Max.DB.FetchQueue"), embeddings ("Max.Embedder"),
-- captions, reminders.  Commands run inline on the event loop and are
-- bounded.  That leaves the agent loop as the only thing worth
-- waiting for.
--
-- __What still gets dropped.__  A trigger arriving mid-drain is persisted but
-- not dispatched (logged with its message_id).  NapCat dials in over reverse
-- WS and does not provide a durable cursor while we're down.  Reconnect now
-- performs a bounded, deduplicated message-history backfill for known QQ
-- endpoints before admitting that generation's live frames, but it cannot
-- prove an offline-complete interval or reconstruct absent notices.  Reactions,
-- recalls and messages outside the returned windows therefore remain possible
-- gaps, recorded as best-effort recovery rather than exactly-once continuity.
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

-- | Long-lived sibling of the other workers: sleeps until the signal
-- handler calls 'beginDrain', waits out the in-flight dispatches, then
-- raises 'UserInterrupt' on the main thread.
--
-- The handler itself only flips the flag — keeping the waiting and the
-- reporting here means shutdown gets logged through the normal effect
-- stack instead of a bare @hPutStrLn stderr@, and the handler stays
-- non-blocking.
--
-- 'UserInterrupt' specifically, because that is what Ctrl+C raises:
-- every @bracket@ in @main@ (DB pool, sandbox and browser teardown)
-- already unwinds correctly for it, so graceful and interactive exit
-- follow one code path.
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
