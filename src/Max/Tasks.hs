-- | Process-local visibility, cancellation and heartbeat for active work.
module Max.Tasks
  ( -- * Registry
    TaskRegistry,
    newTaskRegistry,

    -- * Lifecycle
    TaskId (..),
    TurnRuntime,
    beginTurnRuntime,
    beginDurableTurnRuntime,
    activateTurnRuntime,
    finishTurnRuntime,
    turnRuntimeTaskId,
    turnRuntimeAgentTurn,
    turnRuntimeOutputContext,
    setTurnPhase,
    awaitTurnSilence,
    checkTurnCancellation,
    authorizeTurnOutput,

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
import Control.Exception (Exception (..), asyncExceptionFromException, asyncExceptionToException, throwIO)
import Control.Monad (unless, when)
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
import Max.Platform.Types (CanonicalMessageId (..))
import Max.Turn.Types (AgentTurnId (..), AgentTurnRef (..), TurnOutputContext, newTurnOutputContext)
import OneBot.Types (GroupId (..), UserId (..))

-- | Short, human-typeable id like @t17@ — easy to !kill from the
-- group.  Counter resets on restart.
newtype TaskId = TaskId {unTaskId :: Text}
  deriving stock (Show, Eq, Ord)

-- | The explicit lifecycle object for one dispatch.  The task entry remains
-- process-local, while production turns also carry their durable identity and
-- one shared visible-output ordinal allocator.  Tests can
-- still create an in-memory-only runtime with 'beginTurnRuntime'.
data TurnRuntime = TurnRuntime
  { trEntry :: !TaskEntry,
    trAgentTurn :: !(Maybe AgentTurnRef),
    trOutputContext :: !(Maybe TurnOutputContext)
  }

-- | The one registry entry.  Fields the agent loop supplies are 'TVar's
-- because the entry outlives the window in which they are unknown.
data TaskEntry = TaskEntry
  { teId :: !TaskId,
    teGroup :: !GroupId,
    -- | Who triggered this turn.  Shown by @!ps@; does /not/ gate who
    -- may steer it (module header).
    teUser :: !UserId,
    -- | The message that triggered the dispatch, when there is one.
    -- 'Nothing' for a poke (no message) and for synthetic dispatches.
    -- This is what @!feedback@ resolves a reply against.
    teTrigger :: !(Maybe Int64),
    -- | Durable identity, present on production dispatches.  Exact replies to
    -- linked bot output use this to steer the producing turn without a
    -- task-boundary classifier.
    teAgentTurn :: !(Maybe AgentTurnRef),
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
    teKilled :: !(TVar Bool)
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
    -- | When this turn last changed phase.  Age answers "how long has this
    -- been running", which a healthy long turn also answers; this answers
    -- "when was it last seen moving", which only a wedged one answers badly.
    tiProgressAt :: !UTCTime
  }
  deriving stock (Show)

newtype TaskRegistry = TaskRegistry
  { trState :: TVar (Int, Map TaskId TaskEntry)
  }

newTaskRegistry :: IO TaskRegistry
newTaskRegistry = TaskRegistry <$> newTVarIO (0, Map.empty)

-- | User cancellation is asynchronous so 'catchSync' cannot swallow it.
-- Resource brackets still run; the dispatch root handles the final exception.
data TaskCancelled = TaskCancelled
  deriving stock (Show)

instance Exception TaskCancelled where
  toException = asyncExceptionToException
  fromException = asyncExceptionFromException

--------------------------------------------------------------------------------
-- Lifecycle

-- | Create the one runtime object that owns a dispatch's task lifecycle.
-- Visibility begins in the same STM transaction that allocates its task id,
-- before context/media collection or any LLM call.
beginTurnRuntime :: TaskRegistry -> GroupId -> UserId -> Maybe CanonicalMessageId -> IO TurnRuntime
beginTurnRuntime reg gid uid mTrigger =
  beginTurnRuntimeWith reg Nothing Nothing gid uid mTrigger

-- | Production constructor.  The caller has already committed the
-- @agent_turns@ row, so the in-memory registry can never advertise a turn
-- whose durable identity does not exist.
beginDurableTurnRuntime ::
  TaskRegistry ->
  AgentTurnRef ->
  GroupId ->
  UserId ->
  Maybe CanonicalMessageId ->
  IO TurnRuntime
beginDurableTurnRuntime reg durable gid uid mTrigger = do
  output <- newTurnOutputContext durable
  beginTurnRuntimeWith reg (Just durable) (Just output) gid uid mTrigger

beginTurnRuntimeWith ::
  TaskRegistry ->
  Maybe AgentTurnRef ->
  Maybe TurnOutputContext ->
  GroupId ->
  UserId ->
  Maybe CanonicalMessageId ->
  IO TurnRuntime
beginTurnRuntimeWith reg durable output gid uid mTrigger = do
  now <- getCurrentTime
  kind <- newTVarIO "starting"
  -- Seeded with the start time rather than left empty: a turn that has not
  -- reached its first phase yet has still only been silent since it began, and
  -- a Maybe here would make every reader answer that question again.
  progressAt <- newTVarIO now
  cancel <- newTVarIO Nothing
  killed <- newTVarIO False
  atomically $ do
    (n, m) <- readTVar reg.trState
    let tid = TaskId ("t" <> T.pack (show (n + 1)))
        entry =
          TaskEntry
            { teId = tid,
              teGroup = gid,
              teUser = uid,
              teTrigger = realTrigger mTrigger,
              teAgentTurn = durable,
              teStartedAt = now,
              teKind = kind,
              teProgressAt = progressAt,
              teCancel = cancel,
              teKilled = killed
            }
    writeTVar reg.trState (n + 1, Map.insert tid entry m)
    pure
      TurnRuntime
        { trEntry = entry,
          trAgentTurn = durable,
          trOutputContext = output
        }
  where
    realTrigger = \case
      Just (CanonicalMessageId message) | message /= 0 -> Just message
      _ -> Nothing

turnRuntimeTaskId :: TurnRuntime -> TaskId
turnRuntimeTaskId turn = turn.trEntry.teId

turnRuntimeAgentTurn :: TurnRuntime -> Maybe AgentTurnRef
turnRuntimeAgentTurn = (.trAgentTurn)

turnRuntimeOutputContext :: TurnRuntime -> Maybe TurnOutputContext
turnRuntimeOutputContext = (.trOutputContext)

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

-- | Enter a phase and stamp the heartbeat, which are the same event: a turn is
-- observably alive exactly when it moves.  Every writer of 'teKind' goes
-- through here so the two cannot drift into disagreeing about when this turn
-- was last seen.
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

-- | The dispatch root atomically drops its process-local visibility.
finishTurnRuntime :: TaskRegistry -> TurnRuntime -> IO ()
finishTurnRuntime reg turn =
  atomically $
    modifyTVar' reg.trState (second (Map.delete turn.trEntry.teId))

-- | Message ids in @gid@ that some turn is already handling: triggers
-- belonging to live dispatches.  'Max.Prompt.buildContext' uses this
-- to stop a concurrent dispatch answering a question that is already
-- being answered.
inFlightTriggers :: TaskRegistry -> GroupId -> IO (Set Int64)
inFlightTriggers reg gid = atomically $ do
  (_, m) <- readTVar reg.trState
  let mine = filter (\e -> e.teGroup == gid) (Map.elems m)
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

-- | Trigger the cancel action for one task.  'False' means the id is
-- unknown (the task already finished).
--
-- A task still in its prologue has no cancel action yet; the kill is
-- recorded on the entry and 'activateTurnRuntime' hands it to the loop, which
-- dies before doing a turn's work.  Either way the user gets told the
-- kill was accepted, which is the truth.
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

-- | Stop the turn carrying this durable identity, if it is running here.
--
-- The reconciler's side of ADR 007: a plan that was steered no longer wants
-- some child, and the way to stop a turn is the way @!kill@ already stops one.
-- 'False' means no live turn in this process is that one — it finished, or it
-- is running on another node — and the caller can only say so.
cancelAgentTurnTask :: TaskRegistry -> AgentTurnId -> IO Bool
cancelAgentTurnTask reg turnId = do
  (_, entries) <- readTVarIO reg.trState
  let matches =
        [entry.teId | entry <- Map.elems entries, fmap (.atrTurnId) entry.teAgentTurn == Just turnId]
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

-- | Revocation precedes the cancellation signal, including if a worker masks it.
authorizeTurnOutput :: TaskRegistry -> GroupId -> AgentTurnId -> IO Bool
authorizeTurnOutput registry group turn = atomically $ do
  (_, entries) <- readTVar registry.trState
  case [entry | entry <- Map.elems entries, entry.teGroup == group, fmap (.atrTurnId) entry.teAgentTurn == Just turn] of
    [entry] -> not <$> readTVar entry.teKilled
    _ -> pure False
