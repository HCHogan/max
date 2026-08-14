-- |
-- In-flight task registry, scoped per bot process.  One entry per agent
-- dispatch, created the moment the dispatch starts and dropped when it
-- ends.  Lost on restart by design — tasks are by definition ephemeral
-- work-in-progress.
--
-- Each entry carries an inbox the agent loop drains between tool rounds;
-- @!feedback@, an implicit supplement and a poke all push into it.
-- @!ps@ enumerates entries; @!kill@ runs the entry's cancel action,
-- typically a @throwTo@ at the worker thread.  The dispatch root finalizes the
-- runtime on every exit path.
--
-- __One runtime, created early.__  'beginTurnRuntime' creates the entry at
-- dispatch entry, not the agent loop: session load, the supplement
-- classifier's own LLM round-trip and 'Max.Prompt.buildContext' waiting
-- up to 30s for the trigger's images all run before a loop exists.  A
-- registry that only heard about a dispatch once its loop started would
-- spend that window telling @!ps@ the group was idle, telling @!kill@
-- there was nothing to kill, and telling a concurrent trigger that this
-- question was still unanswered.  That exact 'TurnRuntime' is passed to the
-- loop, which fills in what only it can supply (the cancel action) and honours
-- a @!kill@ that arrived while it booted.  No trigger-id adoption is involved
-- on the production path.
--
-- __Steering is not owner-scoped.__  Anybody may feed a running turn.
-- Notes are rendered the way history lines are — @[#id] \<name\>: text@ —
-- so the model sees who contributed what and can address them.
--
-- The registry remains a small STM runtime rather than an Effectful effect:
-- tests construct it in memory, while Agent receives only its per-turn object.
module Max.Tasks
  ( -- * Registry
    TaskRegistry,
    newTaskRegistry,

    -- * Lifecycle
    TaskId (..),
    TaskHandle (..),
    TurnRuntime,
    TurnCompletion (..),
    beginTurnRuntime,
    beginDurableTurnRuntime,
    beginDurableTurnRuntimeAt,
    activateTurnRuntime,
    finishTurnRuntime,
    turnRuntimeTaskId,
    turnRuntimeAgentTurn,
    turnRuntimeOutputContext,
    setTurnPhase,
    checkTurnCancellation,
    drainTurnInbox,
    requeueTurnInbox,
    beginDispatch,
    endDispatch,
    attachTask,
    releaseTask,

    -- * Operations
    Note (..),
    NoteVerb (..),
    TaskInfo (..),
    listTasks,
    cancelTask,
    cancelAgentTurnTask,
    cancelAllTasks,
    drainInbox,
    requeueInbox,
    pushToTrigger,
    pushToAgentTurn,
    pushToLatest,
    inFlightTriggers,
    absorbedTriggers,

    -- * Exception
    TaskCancelled (..),
  )
where

import Control.Concurrent.STM
import Control.Exception (Exception (..), asyncExceptionFromException, asyncExceptionToException, throwIO)
import Control.Monad (filterM, void, when)
import Data.Foldable (for_)
import Data.Int (Int64)
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes, isNothing, mapMaybe)
import Data.Ord (Down (..))
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime, getCurrentTime)
import Max.Dispatch (DispatchMessage)
import Max.Platform.Types (CanonicalMessageId (..))
import Max.Turn.Types (AgentTurnId (..), AgentTurnRef (..), TurnOutputContext, newTurnOutputContext, newTurnOutputContextAt)
import OneBot.Types (GroupId (..), UserId (..))

-- | Short, human-typeable id like @t17@ — easy to !kill from the
-- group.  Counter resets on restart.
newtype TaskId = TaskId {unTaskId :: Text}
  deriving stock (Show, Eq, Ord)

-- | One inbox note: the rendered line the model reads, plus — when
-- the note IS a message (the implicit-supplement path swallowing a
-- real trigger) rather than a note about one — the original event.
-- The source is what lets a note a dying turn accepted but never
-- served be re-dispatched as a turn of its own; the registry only
-- carries it, 'Max.Handler''s dispatch epilogue owns the decision.
data Note = Note
  { noteLine :: !Text,
    noteSource :: !(Maybe DispatchMessage),
    -- | Where the note came from.  The registry only carries it; the one place
    -- it is read is "Max.Effects.Agent", which uses it to label the line for
    -- the model.
    noteVerb :: !NoteVerb
  }

-- | Whether somebody /said/ this note is about the running work.
--
-- Attribution, not interpretation — which is the whole reason it is safe to
-- attach at ingest.  'NoteSteer' records a fact the speaker asserted (they
-- typed @!feedback@, or replied to this turn's own output); 'NoteAmbient'
-- records a fact about timing and nothing else. What either one /means/ is
-- decided downstream by the model holding the conversation, which may treat an
-- ambient line as a course correction or a steer as beside the point.
--
-- ADR 007 §8: no classifier assigns these, because "is this about the running
-- task" is a question about meaning and was being answered by the wrong actor.
data NoteVerb
  = NoteSteer
  | NoteAmbient
  deriving stock (Show, Eq)

-- | The handle the agent loop keeps once it has 'attachTask'ed.  Used
-- to drain its own inbox and (via 'releaseTask') to release the slot.
data TaskHandle = TaskHandle
  { thId :: !TaskId,
    thInbox :: !(TVar [Note]),
    -- | A @!kill@ landed while the dispatch was still in its prologue,
    -- before there was a cancel action to run.  The loop honours it
    -- immediately instead of doing a turn's worth of work first.
    thPreKilled :: !Bool,
    -- | 'attachTask' had to create the entry — no 'beginDispatch' ran
    -- for this dispatch.  Then and only then does 'releaseTask' delete
    -- it; normally the dispatch's own @finally@ owns that.
    thOwned :: !Bool
  }

-- | The explicit lifecycle object for one dispatch.  The task entry remains
-- process-local, while production turns also carry their durable identity and
-- one shared visible-output ordinal allocator.  Tests and legacy helpers can
-- still create an in-memory-only runtime with 'beginTurnRuntime'.
data TurnRuntime = TurnRuntime
  { trEntry :: !TaskEntry,
    trAgentTurn :: !(Maybe AgentTurnRef),
    trOutputContext :: !(Maybe TurnOutputContext)
  }

data TurnCompletion = TurnCompletion
  { tcAbsorbedTriggers :: !(Set Int64),
    tcUnservedNotes :: ![Note]
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
    teInbox :: !(TVar [Note]),
    -- | Messages this turn swallowed as supplements.  Reported by
    -- 'inFlightTriggers' alongside 'teTrigger' so a concurrent dispatch
    -- doesn't helpfully answer them a second time, and accepted by
    -- 'pushToTrigger' so replying to one of them reaches this turn.
    teAbsorbed :: !(TVar (Set Int64)),
    -- | Label shown in @!ps@: @"starting"@ until the loop attaches.
    teKind :: !(TVar Text),
    -- | When the phase last changed — this turn's heartbeat (issue #17).
    --
    -- 'setTurnPhase' fires at every round boundary in "Max.Effects.Agent", so
    -- a turn that is making rounds keeps stamping and one wedged inside a
    -- single tool call stops.  The granularity is therefore the /round/, not
    -- the tool call: a round carrying three slow tools stamps once, at its
    -- start.  That is the right coarseness for "is anybody home?" and the
    -- wrong one for pricing an individual tool, which is a separate ceiling.
    --
    -- Distinct from 'teStartedAt' for the reason a watchdog exists at all: age
    -- says how long a turn has been running, which a legitimately long turn
    -- also reports, and only silence distinguishes the two.
    teProgressAt :: !(TVar UTCTime),
    -- | What to run when @!kill@ targets this task.  'Nothing' until
    -- 'attachTask' supplies it.
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
    tiProgressAt :: !UTCTime,
    -- | Notes pending in the inbox — useful for seeing whether your
    -- @!feedback@ landed.
    tiPending :: !Int
  }
  deriving stock (Show)

newtype TaskRegistry = TaskRegistry
  { trState :: TVar (Int, Map TaskId TaskEntry)
  }

newTaskRegistry :: IO TaskRegistry
newTaskRegistry = TaskRegistry <$> newTVarIO (0, Map.empty)

-- | Custom exception so we can distinguish a user-initiated @!kill@
-- from generic 'ThreadKilled' / shutdown.  Tagged as asynchronous
-- ('asyncExceptionToException') because it is delivered via @throwTo@:
-- 'catchSync' / 'trySyncIO' rethrow it, so it punches through the
-- log-and-continue handlers and error-to-Left wrappers on the worker
-- (we want @!kill@ to actually kill the task, wherever it is — mid
-- HTTP call included).  The agent's @bracket@ still releases on the
-- way out; the dispatch root catches it for the quiet log.
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

-- | Recovery constructor.  Visible-output indices already committed before
-- process death remain occupied; continuation starts after the ledger's
-- current maximum rather than resetting the process-local allocator to zero.
beginDurableTurnRuntimeAt ::
  TaskRegistry ->
  AgentTurnRef ->
  Int ->
  GroupId ->
  UserId ->
  Maybe CanonicalMessageId ->
  IO TurnRuntime
beginDurableTurnRuntimeAt reg durable firstChunk gid uid mTrigger = do
  output <- newTurnOutputContextAt durable firstChunk
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
  inbox <- newTVarIO []
  absorbed <- newTVarIO Set.empty
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
              teInbox = inbox,
              teAbsorbed = absorbed,
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

checkTurnCancellation :: TurnRuntime -> IO ()
checkTurnCancellation turn = do
  let entry = turn.trEntry
  killed <- readTVarIO entry.teKilled
  when killed (throwIO TaskCancelled)

drainTurnInbox :: TurnRuntime -> IO [Note]
drainTurnInbox turn = atomically $ do
  let entry = turn.trEntry
  notes <- readTVar entry.teInbox
  writeTVar entry.teInbox []
  pure notes

requeueTurnInbox :: TurnRuntime -> [Note] -> IO ()
requeueTurnInbox turn notes =
  atomically (modifyTVar' turn.trEntry.teInbox (notes <>))

-- | The dispatch root is the sole finalizer.  It atomically removes the task
-- and returns everything its epilogue needs, so cleanup cannot observe a
-- half-removed entry.  Killed turns deliberately drop pending notes.
finishTurnRuntime :: TaskRegistry -> TurnRuntime -> IO TurnCompletion
finishTurnRuntime reg turn = atomically $ do
  let entry = turn.trEntry
  (n, entries) <- readTVar reg.trState
  absorbed <- readTVar entry.teAbsorbed
  killed <- readTVar entry.teKilled
  notes <- if killed then pure [] else readTVar entry.teInbox
  writeTVar reg.trState (n, Map.delete entry.teId entries)
  pure
    TurnCompletion
      { tcAbsorbedTriggers = absorbed,
        tcUnservedNotes = notes
      }

-- | Open an entry for a dispatch that is starting.  Call at dispatch
-- entry, ahead of the slow prologue — see the module header.
--
-- @trigger@ is the message that caused it; pass 'Nothing' when there
-- isn't one.  A poke's synthetic canonical id 0 counts as no trigger:
-- it is a sentinel every poke shares, so treating it as a real id would
-- make two concurrent pokes indistinguishable.
beginDispatch :: TaskRegistry -> GroupId -> UserId -> Maybe CanonicalMessageId -> IO TaskId
beginDispatch reg gid uid mTrigger =
  turnRuntimeTaskId <$> beginTurnRuntime reg gid uid mTrigger

-- | Close it.  Belongs in the same @finally@ that releases the shutdown
-- slot: a leak here would make a finished question look permanently
-- in-flight to every later turn.
--
-- Returns the notes the entry accepted but nobody consumed — pushing
-- into an inbox came with a 托腮 on the message, and ending the task
-- is where that promise either transfers (the caller re-dispatches
-- what carries a source) or is formally dropped.  A killed task
-- returns none: @!kill@ means "stop this thread of work", notes
-- included, and quietly reviving them would surprise whoever killed it.
endDispatch :: TaskRegistry -> TaskId -> IO [Note]
endDispatch reg tid = atomically $ do
  (n, m) <- readTVar reg.trState
  writeTVar reg.trState (n, Map.delete tid m)
  case Map.lookup tid m of
    Nothing -> pure []
    Just e -> do
      killed <- readTVar e.teKilled
      if killed then pure [] else readTVar e.teInbox

-- | The agent loop takes ownership of the entry 'beginDispatch' opened
-- for it, identified by the trigger it was given.  Supplies the cancel
-- action and the real kind label.
--
-- Falls back to creating an entry when there is none to adopt, so
-- 'Max.Effects.Agent.agentTurn' stays usable on its own; the returned
-- handle records which case it was so 'releaseTask' knows whether the
-- entry is its to delete.
attachTask ::
  TaskRegistry ->
  GroupId ->
  UserId ->
  -- | The dispatch's trigger message, matched against 'teTrigger'.
  Maybe CanonicalMessageId ->
  -- | Kind label shown in @!ps@; "llm" / "search" / etc.
  Text ->
  -- | Cancel action; runs when 'cancelTask' targets this entry.
  IO () ->
  IO TaskHandle
attachTask reg gid uid mTrigger kind cancel = do
  now <- getCurrentTime
  mAdopted <- atomically $ do
    (_, m) <- readTVar reg.trState
    candidates <- filterM adoptable (Map.elems m)
    case candidates of
      [] -> pure Nothing
      (e : _) -> do
        writePhase e now kind
        writeTVar e.teCancel (Just cancel)
        killed <- readTVar e.teKilled
        pure (Just (e, killed))
  case mAdopted of
    Just (e, killed) ->
      pure
        TaskHandle
          { thId = e.teId,
            thInbox = e.teInbox,
            thPreKilled = killed,
            thOwned = False
          }
    Nothing -> do
      tid <- beginDispatch reg gid uid mTrigger
      inbox <- atomically $ do
        (_, m) <- readTVar reg.trState
        case Map.lookup tid m of
          -- Unreachable: we just created it and nothing else holds the
          -- id.  A fresh inbox keeps the loop running rather than
          -- crashing a turn over registry bookkeeping.
          Nothing -> newTVar []
          Just e -> do
            writePhase e now kind
            writeTVar e.teCancel (Just cancel)
            pure e.teInbox
      pure
        TaskHandle
          { thId = tid,
            thInbox = inbox,
            thPreKilled = False,
            thOwned = True
          }
  where
    -- Same group, same trigger, and no loop has claimed it yet — a
    -- claimed entry means some other dispatch got there first, and
    -- stealing it would leave two loops draining one inbox.  A poke has
    -- no trigger to match on (they all share the sentinel id), so it
    -- never adopts and always opens its own entry.
    adoptable e = case mTrigger of
      Just (CanonicalMessageId t)
        | t /= 0 && e.teGroup == gid && e.teTrigger == Just t ->
            isNothing <$> readTVar e.teCancel
      _ -> pure False

-- | Counterpart to 'attachTask'.  A no-op for an adopted entry: the
-- dispatch's own @finally@ calls 'endDispatch' for that one, and
-- deleting it here would drop the entry while the shutdown slot and
-- the reaction cleanup still believe it exists.
-- | (Unserved notes from a self-owned entry are dropped: a standalone
-- 'Max.Effects.Agent.agentTurn' has no dispatch epilogue to hand them
-- to.)
releaseTask :: TaskRegistry -> TaskHandle -> IO ()
releaseTask reg h
  | h.thOwned = void (endDispatch reg h.thId)
  | otherwise = pure ()

--------------------------------------------------------------------------------
-- Operations

drainInbox :: TaskHandle -> IO [Note]
drainInbox h = atomically $ do
  xs <- readTVar h.thInbox
  writeTVar h.thInbox []
  pure xs

-- | Put drained notes back (at the front, preserving order).  For the
-- loop discovering it can no longer answer them — the invariant is
-- that a note leaves the inbox only by entering the conversation, so
-- what the loop can't consume must go back for 'endDispatch' to
-- surface.
requeueInbox :: TaskHandle -> [Note] -> IO ()
requeueInbox h xs = atomically $ modifyTVar' h.thInbox (xs <>)

-- | Append a note to the turn triggered by @mid@ — or to the turn that
-- swallowed @mid@ as a supplement, so replying to your own absorbed
-- message still reaches the turn now carrying it.
--
-- 'Nothing' means no live turn owns that message; callers fall back to
-- 'pushToLatest' rather than reporting an error, because a @!feedback@
-- that refuses to land leaves the note in nobody's context at all.
pushToTrigger :: TaskRegistry -> GroupId -> Maybe TaskId -> Maybe Int64 -> Int64 -> Note -> IO (Maybe TaskId)
pushToTrigger reg gid except absorb mid note = atomically $ do
  (_, m) <- readTVar reg.trState
  let mine =
        filter (\e -> e.teGroup == gid && Just e.teId /= except) (Map.elems m)
  matches <- filterM owns mine
  case sortOn (Down . teStartedAt) matches of
    [] -> pure Nothing
    (e : _) -> do
      modifyTVar' e.teInbox (<> [note])
      for_ absorb $ \a -> modifyTVar' e.teAbsorbed (Set.insert a)
      pure (Just e.teId)
  where
    owns e
      | e.teTrigger == Just mid = pure True
      | otherwise = Set.member mid <$> readTVar e.teAbsorbed

-- | Append directly to the live runtime carrying a durable agent turn.  This
-- is the L3 reply path: the database resolves an output message to t# first,
-- then the process-local registry performs the steer if that exact turn is
-- still alive.  A race with finalization returns 'Nothing' and the caller
-- falls back to a fresh dispatch.
pushToAgentTurn :: TaskRegistry -> GroupId -> Maybe TaskId -> Maybe Int64 -> AgentTurnRef -> Note -> IO (Maybe TaskId)
pushToAgentTurn reg gid except absorb durable note = atomically $ do
  (_, entries) <- readTVar reg.trState
  let matches =
        [ entry
        | entry <- Map.elems entries,
          entry.teGroup == gid,
          Just entry.teId /= except,
          entry.teAgentTurn == Just durable
        ]
  case sortOn (Down . teStartedAt) matches of
    [] -> pure Nothing
    entry : _ -> do
      modifyTVar' entry.teInbox (<> [note])
      for_ absorb $ \messageId -> modifyTVar' entry.teAbsorbed (Set.insert messageId)
      pure (Just entry.teId)

-- | Append a note to the group's most recently started turn.
--
-- @except@ is the caller's own entry, when the caller is itself a
-- dispatch asking whether somebody /else/ is already working.  Since
-- 'beginDispatch' opens the entry before the supplement classifier
-- runs, a dispatch that didn't exclude itself would find itself,
-- inject into its own inbox, and then drop the note on the floor when
-- it exits.
--
-- @absorb@ is the id of the message the note /is/ (the implicit
-- supplement path, where a real @-trigger gets swallowed) as opposed to
-- a note merely about it (@!feedback@).  Recording it keeps
-- 'inFlightTriggers' reporting that message as taken for as long as the
-- absorbing turn runs — otherwise the dispatch that swallowed it
-- finishes its own bookkeeping immediately and the next turn sees an
-- unanswered question.
--
-- 'Nothing' means the group has no other turn running.
pushToLatest :: TaskRegistry -> GroupId -> Maybe TaskId -> Maybe Int64 -> Note -> IO (Maybe TaskId)
pushToLatest reg gid except absorb note = atomically $ do
  (_, m) <- readTVar reg.trState
  let mine =
        filter (\e -> e.teGroup == gid && Just e.teId /= except) (Map.elems m)
  case sortOn (Down . teStartedAt) mine of
    [] -> pure Nothing
    (e : _) -> do
      modifyTVar' e.teInbox (<> [note])
      for_ absorb $ \a -> modifyTVar' e.teAbsorbed (Set.insert a)
      pure (Just e.teId)

-- | Message ids one task has swallowed — the turn's own trigger not
-- included.  Read by the dispatch epilogue to take the 托腮 reaction
-- back off each absorbed message (the turn that owns them is done);
-- must run before 'endDispatch' drops the entry.
absorbedTriggers :: TaskRegistry -> TaskId -> IO [Int64]
absorbedTriggers reg tid = atomically $ do
  (_, m) <- readTVar reg.trState
  case Map.lookup tid m of
    Nothing -> pure []
    Just e -> Set.toList <$> readTVar e.teAbsorbed

-- | Message ids in @gid@ that some turn is already handling: triggers
-- and anything they have absorbed.  'Max.Prompt.buildContext' uses this
-- to stop a concurrent dispatch answering a question that is already
-- being answered.
inFlightTriggers :: TaskRegistry -> GroupId -> IO (Set Int64)
inFlightTriggers reg gid = atomically $ do
  (_, m) <- readTVar reg.trState
  let mine = filter (\e -> e.teGroup == gid) (Map.elems m)
  absorbed <- traverse (readTVar . teAbsorbed) mine
  pure (Set.fromList (mapMaybe teTrigger mine) <> Set.unions absorbed)

listTasks :: TaskRegistry -> Maybe GroupId -> IO [TaskInfo]
listTasks reg mGid = atomically $ do
  (_, m) <- readTVar reg.trState
  let entries = case mGid of
        Just gid -> filter (\e -> e.teGroup == gid) (Map.elems m)
        Nothing -> Map.elems m
  traverse toInfo (sortOn teStartedAt entries)
  where
    toInfo e = do
      pending <- length <$> readTVar e.teInbox
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
            tiProgressAt = progressAt,
            tiPending = pending
          }

-- | Trigger the cancel action for one task.  'False' means the id is
-- unknown (the task already finished).
--
-- A task still in its prologue has no cancel action yet; the kill is
-- recorded on the entry and 'attachTask' hands it to the loop, which
-- dies before doing a turn's work.  Either way the user gets told the
-- kill was accepted, which is the truth.
cancelTask :: TaskRegistry -> TaskId -> IO Bool
cancelTask reg tid = do
  mAct <- atomically $ do
    (_, m) <- readTVar reg.trState
    case Map.lookup tid m of
      Nothing -> pure Nothing
      Just e -> do
        writeTVar e.teKilled True
        Just <$> readTVar e.teCancel
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
          writeTVar e.teKilled True
          readTVar e.teCancel
      )
      (Map.elems m)
  sequence_ (catMaybes acts)
  pure (length acts)
