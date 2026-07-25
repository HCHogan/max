-- |
-- In-flight task registry, scoped per bot process.  One entry per agent
-- dispatch, created the moment the dispatch starts and dropped when it
-- ends.  Lost on restart by design — tasks are by definition ephemeral
-- work-in-progress.
--
-- Each entry carries an inbox the agent loop drains between tool rounds;
-- @!feedback@, an implicit supplement and a poke all push into it.
-- @!ps@ enumerates entries; @!kill@ runs the entry's cancel action,
-- typically a @throwTo@ at the worker thread (the agent's @bracket@
-- releases cleanly on the way out).
--
-- __One index, created early.__  'beginDispatch' creates the entry at
-- dispatch entry, not the agent loop: session load, the supplement
-- classifier's own LLM round-trip and 'Max.Prompt.buildContext' waiting
-- up to 30s for the trigger's images all run before a loop exists.  A
-- registry that only heard about a dispatch once its loop started would
-- spend that window telling @!ps@ the group was idle, telling @!kill@
-- there was nothing to kill, and telling a concurrent trigger that this
-- question was still unanswered.  The loop therefore 'attachTask's to
-- the entry already there, filling in what only it can supply (the
-- cancel action) and honouring a @!kill@ that arrived while it booted.
--
-- __Steering is not owner-scoped.__  Anybody may feed a running turn.
-- Notes are rendered the way history lines are — @[#id] \<name\>: text@ —
-- so the model sees who contributed what and can address them.
--
-- Not an effect (yet): the registry is a plain handle threaded through
-- @main@.  If we ever need to mock for tests, we can swap to a @Tasks@
-- effect that wraps these operations — the call sites are already
-- constrained enough that it'd be a mechanical change.
module Max.Tasks
  ( -- * Registry
    TaskRegistry,
    newTaskRegistry,

    -- * Lifecycle
    TaskId (..),
    TaskHandle (..),
    beginDispatch,
    endDispatch,
    attachTask,
    releaseTask,

    -- * Operations
    TaskInfo (..),
    listTasks,
    cancelTask,
    cancelAllTasks,
    drainInbox,
    pushToTrigger,
    pushToLatest,
    inFlightTriggers,

    -- * Exception
    TaskCancelled (..),
  )
where

import Control.Concurrent.STM
import Control.Exception (Exception (..), asyncExceptionFromException, asyncExceptionToException)
import Control.Monad (filterM)
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
import OneBot.Types (GroupId (..), MessageId (..), UserId (..))

-- | Short, human-typeable id like @t17@ — easy to !kill from the
-- group.  Counter resets on restart.
newtype TaskId = TaskId {unTaskId :: Text}
  deriving stock (Show, Eq, Ord)

-- | The handle the agent loop keeps once it has 'attachTask'ed.  Used
-- to drain its own inbox and (via 'releaseTask') to release the slot.
data TaskHandle = TaskHandle
  { thId :: !TaskId,
    thInbox :: !(TVar [Text]),
    -- | A @!kill@ landed while the dispatch was still in its prologue,
    -- before there was a cancel action to run.  The loop honours it
    -- immediately instead of doing a turn's worth of work first.
    thPreKilled :: !Bool,
    -- | 'attachTask' had to create the entry — no 'beginDispatch' ran
    -- for this dispatch.  Then and only then does 'releaseTask' delete
    -- it; normally the dispatch's own @finally@ owns that.
    thOwned :: !Bool
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
    teStartedAt :: !UTCTime,
    teInbox :: !(TVar [Text]),
    -- | Messages this turn swallowed as supplements.  Reported by
    -- 'inFlightTriggers' alongside 'teTrigger' so a concurrent dispatch
    -- doesn't helpfully answer them a second time, and accepted by
    -- 'pushToTrigger' so replying to one of them reaches this turn.
    teAbsorbed :: !(TVar (Set Int64)),
    -- | Label shown in @!ps@: @"starting"@ until the loop attaches.
    teKind :: !(TVar Text),
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

-- | Open an entry for a dispatch that is starting.  Call at dispatch
-- entry, ahead of the slow prologue — see the module header.
--
-- @trigger@ is the message that caused it; pass 'Nothing' when there
-- isn't one.  A poke's synthetic 'MessageId' 0 counts as no trigger:
-- it is a sentinel every poke shares, so treating it as a real id would
-- make two concurrent pokes indistinguishable.
beginDispatch :: TaskRegistry -> GroupId -> UserId -> Maybe MessageId -> IO TaskId
beginDispatch reg gid uid mTrigger = do
  now <- getCurrentTime
  inbox <- newTVarIO []
  absorbed <- newTVarIO Set.empty
  kind <- newTVarIO "starting"
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
              teTrigger = realTrigger,
              teStartedAt = now,
              teInbox = inbox,
              teAbsorbed = absorbed,
              teKind = kind,
              teCancel = cancel,
              teKilled = killed
            }
    writeTVar reg.trState (n + 1, Map.insert tid entry m)
    pure tid
  where
    realTrigger = case mTrigger of
      Just (MessageId m) | m /= 0 -> Just m
      _ -> Nothing

-- | Close it.  Belongs in the same @finally@ that releases the shutdown
-- slot: a leak here would make a finished question look permanently
-- in-flight to every later turn.
endDispatch :: TaskRegistry -> TaskId -> IO ()
endDispatch reg tid =
  atomically $ modifyTVar' reg.trState (fmap (Map.delete tid))

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
  Maybe MessageId ->
  -- | Kind label shown in @!ps@; "llm" / "search" / etc.
  Text ->
  -- | Cancel action; runs when 'cancelTask' targets this entry.
  IO () ->
  IO TaskHandle
attachTask reg gid uid mTrigger kind cancel = do
  mAdopted <- atomically $ do
    (_, m) <- readTVar reg.trState
    candidates <- filterM adoptable (Map.elems m)
    case candidates of
      [] -> pure Nothing
      (e : _) -> do
        writeTVar e.teKind kind
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
            writeTVar e.teKind kind
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
      Just (MessageId t)
        | t /= 0 && e.teGroup == gid && e.teTrigger == Just t ->
            isNothing <$> readTVar e.teCancel
      _ -> pure False

-- | Counterpart to 'attachTask'.  A no-op for an adopted entry: the
-- dispatch's own @finally@ calls 'endDispatch' for that one, and
-- deleting it here would drop the entry while the shutdown slot and
-- the reaction cleanup still believe it exists.
releaseTask :: TaskRegistry -> TaskHandle -> IO ()
releaseTask reg h
  | h.thOwned = endDispatch reg h.thId
  | otherwise = pure ()

--------------------------------------------------------------------------------
-- Operations

drainInbox :: TaskHandle -> IO [Text]
drainInbox h = atomically $ do
  xs <- readTVar h.thInbox
  writeTVar h.thInbox []
  pure xs

-- | Append a note to the turn triggered by @mid@ — or to the turn that
-- swallowed @mid@ as a supplement, so replying to your own absorbed
-- message still reaches the turn now carrying it.
--
-- 'Nothing' means no live turn owns that message; callers fall back to
-- 'pushToLatest' rather than reporting an error, because a @!feedback@
-- that refuses to land leaves the note in nobody's context at all.
pushToTrigger :: TaskRegistry -> GroupId -> Maybe TaskId -> Int64 -> Text -> IO (Maybe TaskId)
pushToTrigger reg gid except mid note = atomically $ do
  (_, m) <- readTVar reg.trState
  let mine =
        filter (\e -> e.teGroup == gid && Just e.teId /= except) (Map.elems m)
  matches <- filterM owns mine
  case sortOn (Down . teStartedAt) matches of
    [] -> pure Nothing
    (e : _) -> do
      modifyTVar' e.teInbox (<> [note])
      pure (Just e.teId)
  where
    owns e
      | e.teTrigger == Just mid = pure True
      | otherwise = Set.member mid <$> readTVar e.teAbsorbed

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
pushToLatest :: TaskRegistry -> GroupId -> Maybe TaskId -> Maybe Int64 -> Text -> IO (Maybe TaskId)
pushToLatest reg gid except absorb note = atomically $ do
  (_, m) <- readTVar reg.trState
  let mine =
        filter (\e -> e.teGroup == gid && Just e.teId /= except) (Map.elems m)
  case sortOn (Down . teStartedAt) mine of
    [] -> pure Nothing
    (e : _) -> do
      modifyTVar' e.teInbox (<> [note])
      case absorb of
        Just a -> modifyTVar' e.teAbsorbed (Set.insert a)
        Nothing -> pure ()
      pure (Just e.teId)

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
      pure
        TaskInfo
          { tiId = e.teId,
            tiGroup = e.teGroup,
            tiUser = e.teUser,
            tiTrigger = e.teTrigger,
            tiKind = kind,
            tiStartedAt = e.teStartedAt,
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
