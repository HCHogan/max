-- | Process-local visibility, cancellation and heartbeat for active work.
module Max.Tasks
  ( -- * Registry
    TaskRegistry,
    newTaskRegistry,

    -- * Lifecycle
    TaskId (..),
    TurnRuntime,
    beginTurnRuntime,
    activateTurnRuntime,
    finishTurnRuntime,
    retainTurnWork,
    turnAcceptsWork,
    turnRuntimeTaskId,
    turnRuntimeAgentTurn,
    turnExecutor,
    turnEvents,
    lookupTurnEvents,
    bindTurnEvents,
    turnObservationCursor,
    setTurnObservationCursor,
    setTurnExecutor,
    turnRuntimeOutputContext,
    nextExecutionOrdinal,
    setTurnPhase,
    awaitTurnSilence,
    checkTurnCancellation,
    authorizeTurnOutput,
    turnIsLive,

    -- * Operations
    TaskInfo (..),
    listTasks,
    cancelTask,
    cancelAgentTurnTask,
    cancelAllTasks,
    inFlightTriggers,

    -- * Exception
    TaskCancelled (..),
  )
where

import Control.Concurrent.STM
import Control.Exception (Exception (..), asyncExceptionFromException, asyncExceptionToException, finally, mask, onException, throwIO)
import Control.Monad (filterM, unless, when)
import Data.Bifunctor (second)
import Data.Int (Int64)
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes, mapMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime, getCurrentTime)
import Max.History.Types (MessageCursor)
import Max.Node.Events qualified as Events
import Max.Node.Executor qualified as Executor
import Max.Platform.Types (CanonicalMessageId (..))
import Max.Turn.Types (AgentTurnId (..), AgentTurnRef (..), ExecutionOrdinal (..), TurnOutputContext, newTurnOutputContext, turnOutputAgentTurn)
import OneBot.Types (GroupId (..), UserId (..))

-- | Process-local @!kill@ handle, such as @t17@; resets on restart.
newtype TaskId = TaskId {unTaskId :: Text}
  deriving stock (Show, Eq, Ord)

-- | One dispatch owns its registry entry and tool-result ordinal allocator.
data TurnRuntime = TurnRuntime
  { trEntry :: !TaskEntry,
    trExecutionOrdinal :: !(TVar Int64),
    trExecutor :: !(TVar Executor.Actor),
    trObservationCursor :: !(TVar (Maybe MessageCursor))
  }

-- | Mutable lifecycle state shared with cancellation and visibility queries.
data TaskEntry = TaskEntry
  { teId :: !TaskId,
    teGroup :: !GroupId,
    -- | Triggering user for @!ps@, not an authorization rule.
    teUser :: !UserId,
    -- | The message that triggered the dispatch, when there is one.
    -- 'Nothing' for a poke (no message) and for synthetic dispatches.
    -- This is what @!feedback@ resolves a reply against.
    teTrigger :: !(Maybe Int64),
    teOutputContext :: !TurnOutputContext,
    teStartedAt :: !UTCTime,
    -- | Label shown in @!ps@: @"starting"@ until the loop attaches.
    teKind :: !(TVar Text),
    -- | Last phase change, used by the silence watchdog rather than total age.
    -- Updates occur at round boundaries; a slow multi-tool round has one heartbeat.
    -- Individual tool deadlines are enforced separately.
    teProgressAt :: !(TVar UTCTime),
    -- | What to run when @!kill@ targets this task.  'Nothing' until
    -- 'activateTurnRuntime' supplies it.
    teCancel :: !(TVar (Maybe (IO ()))),
    -- | A @!kill@ has been accepted for this entry.
    teKilled :: !(TVar Bool),
    teDraining :: !(TVar Bool),
    teRetained :: !(TVar [(IO (), IO ())]),
    teEvents :: !(TVar Events.Task)
  }

-- | Public snapshot of one task for @!ps@ output.
data TaskInfo = TaskInfo
  { tiId :: !TaskId,
    tiGroup :: !GroupId,
    tiUser :: !UserId,
    -- | Shown so you know which message to reply to when aiming a
    -- @!feedback@ at this particular turn.
    tiTrigger :: !(Maybe Int64),
    tiKind :: !Text,
    tiStartedAt :: !UTCTime,
    -- | Last phase change; the silence watchdog measures from here.
    tiProgressAt :: !UTCTime
  }
  deriving stock (Show)

newtype TaskRegistry = TaskRegistry
  { trState :: TVar (Int, Map TaskId TaskEntry)
  }

newTaskRegistry :: IO TaskRegistry
newTaskRegistry = TaskRegistry <$> newTVarIO (0, Map.empty)

turnEvents :: TurnRuntime -> STM Events.Task
turnEvents = readTVar . (.trEntry.teEvents)

lookupTurnEvents :: TaskRegistry -> AgentTurnId -> STM (Maybe Events.Task)
lookupTurnEvents registry turn = do
  (_, entries) <- readTVar registry.trState
  case [entry | entry <- Map.elems entries, (turnOutputAgentTurn entry.teOutputContext).atrTurnId == turn] of
    entry : _ -> Just <$> readTVar entry.teEvents
    [] -> pure Nothing

bindTurnEvents :: TaskRegistry -> AgentTurnId -> Events.Task -> STM Bool
bindTurnEvents registry turn events = do
  (_, entries) <- readTVar registry.trState
  case [entry | entry <- Map.elems entries, (turnOutputAgentTurn entry.teOutputContext).atrTurnId == turn] of
    entry : _ -> do
      previous <- readTVar entry.teEvents
      Events.close previous
      writeTVar entry.teEvents events
      pure True
    [] -> pure False

turnObservationCursor :: TurnRuntime -> IO (Maybe MessageCursor)
turnObservationCursor = readTVarIO . (.trObservationCursor)

setTurnObservationCursor :: TurnRuntime -> MessageCursor -> IO ()
setTurnObservationCursor turn cursor = atomically (writeTVar turn.trObservationCursor (Just cursor))

turnExecutor :: TurnRuntime -> IO Executor.Actor
turnExecutor = readTVarIO . (.trExecutor)

setTurnExecutor :: TurnRuntime -> Executor.Actor -> IO ()
setTurnExecutor turn actor = atomically $ do
  previous <- readTVar turn.trExecutor
  Executor.closeTask previous
  writeTVar turn.trExecutor actor

-- | User cancellation is asynchronous so 'catchSync' cannot swallow it.
-- Resource brackets still run; the dispatch root handles the final exception.
data TaskCancelled = TaskCancelled
  deriving stock (Show)

instance Exception TaskCancelled where
  toException = asyncExceptionToException
  fromException = asyncExceptionFromException

--------------------------------------------------------------------------------
-- Lifecycle

-- | Register before context collection. Production callers first create the
-- history row; tests can supply a reference without a database.
beginTurnRuntime :: TaskRegistry -> AgentTurnRef -> GroupId -> UserId -> Maybe CanonicalMessageId -> IO TurnRuntime
beginTurnRuntime reg ref gid uid mTrigger = do
  output <- newTurnOutputContext ref
  now <- getCurrentTime
  kind <- newTVarIO "starting"
  -- Context collection counts toward silence before the first phase change.
  progressAt <- newTVarIO now
  cancel <- newTVarIO Nothing
  killed <- newTVarIO False
  executionOrdinal <- newTVarIO 0
  node <- Executor.newExecutor
  actor <- atomically (Executor.registerTask node ref.atrTurnId Executor.NewRequest)
  executor <- newTVarIO actor
  observationCursor <- newTVarIO Nothing
  atomically $ do
    (n, m) <- readTVar reg.trState
    events <- Events.newNode >>= Events.newTask >>= newTVar
    draining <- newTVar False
    retained <- newTVar []
    let tid = TaskId ("t" <> T.pack (show (n + 1)))
        entry =
          TaskEntry
            { teId = tid,
              teGroup = gid,
              teUser = uid,
              teTrigger = realTrigger mTrigger,
              teOutputContext = output,
              teStartedAt = now,
              teKind = kind,
              teProgressAt = progressAt,
              teCancel = cancel,
              teKilled = killed,
              teDraining = draining,
              teRetained = retained,
              teEvents = events
            }
    writeTVar reg.trState (n + 1, Map.insert tid entry m)
    pure
      TurnRuntime
        { trEntry = entry,
          trExecutionOrdinal = executionOrdinal,
          trExecutor = executor,
          trObservationCursor = observationCursor
        }
  where
    realTrigger = \case
      Just (CanonicalMessageId message) | message /= 0 -> Just message
      _ -> Nothing

turnRuntimeTaskId :: TurnRuntime -> TaskId
turnRuntimeTaskId turn = turn.trEntry.teId

turnRuntimeAgentTurn :: TurnRuntime -> AgentTurnRef
turnRuntimeAgentTurn = turnOutputAgentTurn . turnRuntimeOutputContext

turnRuntimeOutputContext :: TurnRuntime -> TurnOutputContext
turnRuntimeOutputContext = (.trEntry.teOutputContext)

nextExecutionOrdinal :: TurnRuntime -> IO ExecutionOrdinal
nextExecutionOrdinal turn = atomically $ do
  n <- readTVar turn.trExecutionOrdinal
  writeTVar turn.trExecutionOrdinal (n + 1)
  pure (ExecutionOrdinal (n + 1))

-- | Attach the worker's cancellation action and enter its first executable
-- phase.  A kill accepted during context collection is returned explicitly so
-- the caller can stop before spending an LLM turn.
activateTurnRuntime :: TurnRuntime -> Text -> IO () -> IO Bool
activateTurnRuntime turn phase cancel = do
  now <- getCurrentTime
  atomically $ do
    let entry = turn.trEntry
    writePhase entry now phase
    writeTVar entry.teCancel (Just cancel)
    readTVar entry.teKilled

setTurnPhase :: TurnRuntime -> Text -> IO ()
setTurnPhase turn phase = do
  now <- getCurrentTime
  atomically (writePhase turn.trEntry now phase)

-- | Update phase and heartbeat atomically.
writePhase :: TaskEntry -> UTCTime -> Text -> STM ()
writePhase entry now phase = do
  writeTVar entry.teKind phase
  writeTVar entry.teProgressAt now

-- | Wait for @limitMicros@ without a progress update. Each update resets the
-- timer, so this bounds silence rather than total turn age.
awaitTurnSilence :: TurnRuntime -> Int -> IO ()
awaitTurnSilence turn limitMicros = go
  where
    progress = turn.trEntry.teProgressAt
    go = do
      seen <- readTVarIO progress
      timer <- registerDelay limitMicros
      stalled <-
        atomically $
          ( do
              expired <- readTVar timer
              if expired then pure True else retry
          )
            `orElse` ( do
                         current <- readTVar progress
                         if current == seen then retry else pure False
                     )
      unless stalled go

checkTurnCancellation :: TurnRuntime -> IO ()
checkTurnCancellation turn = do
  let entry = turn.trEntry
  killed <- readTVarIO entry.teKilled
  when killed (throwIO TaskCancelled)

-- | Native calls detached by an interrupted await retain the execution scope.
-- The cancellation and join actions come from host-owned Async handles.
retainTurnWork :: TurnRuntime -> IO () -> IO () -> IO ()
retainTurnWork turn cancel await = mask $ \restore -> do
  accepted <- atomically $ do
    draining <- readTVar turn.trEntry.teDraining
    killed <- readTVar turn.trEntry.teKilled
    if draining || killed
      then pure False
      else do
        modifyTVar' turn.trEntry.teRetained ((cancel, await) :)
        pure True
  unless accepted (restore cancel)

-- | Close the model task and release its executor immediately. Execution
-- identity and resources remain until its already-admitted native calls settle.
-- Kill/shutdown now signal those calls instead of the finished model segment.
finishTurnRuntime :: TaskRegistry -> TurnRuntime -> IO ()
finishTurnRuntime reg turn = mask $ \restore -> do
  now <- getCurrentTime
  (retained, killed) <- atomically $ do
    readTVar turn.trExecutor >>= Executor.closeTask
    turnEvents turn >>= Events.close
    let entry = turn.trEntry
    writeTVar entry.teDraining True
    retained <- readTVar entry.teRetained
    unless (null retained) (writePhase entry now "detached calls")
    writeTVar entry.teCancel (Just (mapM_ fst retained))
    killed <- readTVar entry.teKilled
    pure (retained, killed)
  let cancel = mapM_ fst retained
      remove = atomically $ do
        writeTVar turn.trEntry.teRetained []
        modifyTVar' reg.trState (second (Map.delete turn.trEntry.teId))
  (when killed cancel >> restore (mapM_ snd retained) `onException` cancel) `finally` remove

-- | Message ids in @gid@ that some turn is already handling: triggers
-- belonging to live dispatches.  'Max.Prompt.buildContext' uses this
-- to stop a concurrent dispatch answering a question that is already
-- being answered.
inFlightTriggers :: TaskRegistry -> GroupId -> IO (Set Int64)
inFlightTriggers reg gid = atomically $ do
  (_, m) <- readTVar reg.trState
  active <- filterM (fmap not . readTVar . (.teDraining)) (Map.elems m)
  let mine = filter (\e -> e.teGroup == gid) active
  pure (Set.fromList (mapMaybe teTrigger mine))

listTasks :: TaskRegistry -> Maybe GroupId -> IO [TaskInfo]
listTasks reg mGid = atomically $ do
  (_, m) <- readTVar reg.trState
  let entries = case mGid of
        Just gid -> filter (\e -> e.teGroup == gid) (Map.elems m)
        Nothing -> Map.elems m
  traverse toInfo (sortOn teStartedAt entries)
  where
    toInfo e = do
      kind <- readTVar e.teKind
      progressAt <- readTVar e.teProgressAt
      pure
        TaskInfo
          { tiId = e.teId,
            tiGroup = e.teGroup,
            tiUser = e.teUser,
            tiTrigger = e.teTrigger,
            tiKind = kind,
            tiStartedAt = e.teStartedAt,
            tiProgressAt = progressAt
          }

-- | Revoke before signalling. A kill before activation is retained until
-- the worker attaches; repeated kills do not signal again. Unknown ids return False.
cancelTask :: TaskRegistry -> TaskId -> IO Bool
cancelTask reg tid = do
  mAct <- atomically $ do
    (_, m) <- readTVar reg.trState
    case Map.lookup tid m of
      Nothing -> pure Nothing
      Just e -> do
        killed <- readTVar e.teKilled
        writeTVar e.teKilled True
        if killed then pure (Just Nothing) else Just <$> readTVar e.teCancel
  case mAct of
    Nothing -> pure False
    Just act -> sequence_ act >> pure True

-- | Revoke and signal the runtime carrying this turn identity, if still present.
cancelAgentTurnTask :: TaskRegistry -> AgentTurnId -> IO Bool
cancelAgentTurnTask reg turnId = do
  (_, entries) <- readTVarIO reg.trState
  let matches =
        [entry.teId | entry <- Map.elems entries, entryTurnId entry == turnId]
  or <$> traverse (cancelTask reg) matches

-- | Trigger the cancel action for every registered task (all groups —
-- same scope as @!ps --all@).  Returns how many were signalled.
-- Snapshot first, then fire: a cancel action releases its entry via the
-- producer's @bracket@, and we must not mutate under the fold.
cancelAllTasks :: TaskRegistry -> IO Int
cancelAllTasks reg = do
  acts <- atomically $ do
    (_, m) <- readTVar reg.trState
    traverse
      ( \e -> do
          killed <- readTVar e.teKilled
          writeTVar e.teKilled True
          if killed then pure Nothing else readTVar e.teCancel
      )
      (Map.elems m)
  sequence_ (catMaybes acts)
  pure (length acts)

-- | Read in the same STM transaction as job admission and budget reservation.
turnIsLive :: TaskRegistry -> AgentTurnId -> STM Bool
turnIsLive registry turn = do
  (_, entries) <- readTVar registry.trState
  case [entry | entry <- Map.elems entries, entryTurnId entry == turn] of
    [entry] -> not <$> readTVar entry.teKilled
    _ -> pure False

-- | Finished model tasks can only finish calls that were already admitted.
turnAcceptsWork :: TaskRegistry -> AgentTurnId -> STM Bool
turnAcceptsWork registry turn = do
  (_, entries) <- readTVar registry.trState
  case [entry | entry <- Map.elems entries, entryTurnId entry == turn] of
    [entry] -> (&&) <$> (not <$> readTVar entry.teKilled) <*> (not <$> readTVar entry.teDraining)
    _ -> pure False

-- | Revocation precedes the cancellation signal, including if a worker masks it.
authorizeTurnOutput :: TaskRegistry -> GroupId -> AgentTurnId -> IO Bool
authorizeTurnOutput registry group turn = atomically $ do
  (_, entries) <- readTVar registry.trState
  case [entry | entry <- Map.elems entries, entry.teGroup == group, entryTurnId entry == turn] of
    [entry] -> (&&) <$> (not <$> readTVar entry.teKilled) <*> (not <$> readTVar entry.teDraining)
    _ -> pure False

entryTurnId :: TaskEntry -> AgentTurnId
entryTurnId = (.atrTurnId) . turnOutputAgentTurn . (.teOutputContext)
