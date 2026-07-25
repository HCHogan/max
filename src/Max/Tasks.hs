-- |
-- In-flight task registry, scoped per bot process.  Tasks correspond
-- 1:1 to agent dispatches (one per @-mention that triggers the LLM
-- path).  Lost on restart by design — tasks are by definition
-- ephemeral work-in-progress.
--
-- Each task carries a 'btwInbox' 'TVar' the agent loop drains between
-- turns; @!btw@, an implicit supplement and a poke all push into it via
-- 'pushBtwToOwnTask'.  @!ps@ enumerates them; @!kill@ throws a
-- 'TaskCancelled' exception into the task's thread (the agent's
-- @bracket@ unregisters cleanly on the way out).
--
-- __Steering is scoped to whoever started the turn.__  Claude Code's
-- equivalent has exactly one \"you\"; a group has N people, so a note
-- from someone else would steer a turn whose reply is threaded to a
-- different person's message — they'd watch their words answered at
-- somebody else.  A non-owner's note falls through to its own dispatch
-- instead, which every caller already has a path for.
--
-- __'trPending' exists because registration is late.__  'registerTask'
-- runs inside 'Max.Effects.Agent.agentTurn', and everything before it —
-- session load, the supplement classifier's own LLM round-trip,
-- 'Max.Prompt.buildContext' waiting up to 30s for the trigger's images
-- — can burn tens of seconds during which the dispatch is invisible.
-- That is exactly the window in which somebody else asks their own
-- question, so 'inFlightTriggers' reads the pending set rather than the
-- task map.
--
-- Not an effect (yet): the registry is a plain handle threaded
-- through @main@.  If we ever need to mock for tests, we can swap to
-- a @Tasks@ effect that wraps these operations — the call sites are
-- already constrained enough that it'd be a mechanical change.
module Max.Tasks
  ( -- * Registry
    TaskRegistry,
    newTaskRegistry,
    -- * Lifecycle (caller side)
    TaskHandle (..),
    TaskId (..),
    registerTask,
    unregisterTask,

    -- * Dispatch tracking
    beginDispatch,
    endDispatch,
    inFlightTriggers,

    -- * Operations
    TaskInfo (..),
    listTasks,
    cancelTask,
    cancelAllTasks,
    drainBtwInbox,
    pushBtwToOwnTask,
    -- * Exception
    TaskCancelled (..),
  )
where

import Control.Concurrent.STM
import Control.Exception (Exception (..), asyncExceptionFromException, asyncExceptionToException)
import Data.Int (Int64)
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
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

-- | The "handle" the producer side keeps.  Used to drain its own
-- inbox and (via 'unregisterTask') to release the registry slot.
data TaskHandle = TaskHandle
  { thId :: !TaskId,
    thInbox :: !(TVar [Text])
  }

-- | Internal entry stored in the registry.
data TaskEntry = TaskEntry
  { teId :: !TaskId,
    teGroup :: !GroupId,
    -- | Who triggered this turn.  Only they may steer it — see the
    -- module header.
    teUser :: !UserId,
    teKind :: !Text,
    teStartedAt :: !UTCTime,
    teInbox :: !(TVar [Text]),
    -- | What to run when @!kill@ targets this task.  Typically a
    -- @throwTo@ at the worker thread's id.
    teCancel :: !(IO ())
  }

-- | Public, jsonable-ish snapshot of one task for @!ps@ output.
data TaskInfo = TaskInfo
  { tiId :: !TaskId,
    tiGroup :: !GroupId,
    -- | Shown by @!ps@: with steering owner-scoped, whose turn it is
    -- decides whether you can @!btw@ at it.
    tiUser :: !UserId,
    tiKind :: !Text,
    tiStartedAt :: !UTCTime,
    -- | Notes currently pending in the inbox (useful to see whether
    -- the user's @!btw@ landed).
    tiPendingBtw :: !Int
  }
  deriving stock (Show)

data TaskRegistry = TaskRegistry
  { trNextId :: !(TVar Int),
    trMap :: !(TVar (Map TaskId TaskEntry)),
    -- | Trigger message ids with a dispatch under way, registered or
    -- not — see the module header for why this can't just read
    -- 'trMap'.  Claimed at dispatch entry, released by its @finally@.
    trPending :: !(TVar (Map GroupId (Set Int64)))
  }

newTaskRegistry :: IO TaskRegistry
newTaskRegistry =
  TaskRegistry <$> newTVarIO 0 <*> newTVarIO Map.empty <*> newTVarIO Map.empty

-- | Custom exception so we can distinguish a user-initiated @!kill@
-- from generic 'ThreadKilled' / shutdown.  Tagged as asynchronous
-- ('asyncExceptionToException') because it is delivered via @throwTo@:
-- 'catchSync' / 'trySyncIO' rethrow it, so it punches through the
-- log-and-continue handlers and error-to-Left wrappers on the worker
-- (we want @!kill@ to actually kill the task, wherever it is — mid
-- HTTP call included).  The agent's @bracket@ still unregisters on
-- the way out; the dispatch root catches it for the quiet log.
data TaskCancelled = TaskCancelled
  deriving stock (Show)

instance Exception TaskCancelled where
  toException = asyncExceptionToException
  fromException = asyncExceptionFromException

--------------------------------------------------------------------------------
-- Lifecycle

registerTask ::
  TaskRegistry ->
  GroupId ->
  -- | Who triggered the turn; only they may steer it.
  UserId ->
  -- | Kind label shown in @!ps@; "llm" / "search" / etc.
  Text ->
  -- | Cancel action; runs when 'cancelTask' targets this entry.
  IO () ->
  IO TaskHandle
registerTask reg gid uid kind cancel = do
  now <- getCurrentTime
  inbox <- newTVarIO []
  tid <- atomically $ do
    n <- readTVar reg.trNextId
    writeTVar reg.trNextId (n + 1)
    let tid = TaskId ("t" <> T.pack (show (n + 1)))
        entry =
          TaskEntry
            { teId = tid,
              teGroup = gid,
              teUser = uid,
              teKind = kind,
              teStartedAt = now,
              teInbox = inbox,
              teCancel = cancel
            }
    modifyTVar' reg.trMap (Map.insert tid entry)
    pure tid
  pure TaskHandle {thId = tid, thInbox = inbox}

unregisterTask :: TaskRegistry -> TaskHandle -> IO ()
unregisterTask reg h =
  atomically $ modifyTVar' reg.trMap (Map.delete h.thId)

--------------------------------------------------------------------------------
-- Operations

drainBtwInbox :: TaskHandle -> IO [Text]
drainBtwInbox h = atomically $ do
  xs <- readTVar h.thInbox
  writeTVar h.thInbox []
  pure xs

-- | Append a note to @uid@'s most-recently-started task in @gid@.
--
-- 'False' means they have none running — not that the group is idle.
-- Someone else's turn is deliberately not steerable (module header):
-- every caller treats 'False' as \"handle this as its own dispatch\",
-- which is the behaviour we want for a bystander's note.
pushBtwToOwnTask :: TaskRegistry -> GroupId -> UserId -> Text -> IO Bool
pushBtwToOwnTask reg gid uid note = atomically $ do
  m <- readTVar reg.trMap
  let own = Map.elems (Map.filter (\e -> e.teGroup == gid && e.teUser == uid) m)
  case sortOn (Down . teStartedAt) own of
    [] -> pure False
    (latest : _) -> do
      modifyTVar' latest.teInbox (<> [note])
      pure True

--------------------------------------------------------------------------------
-- Dispatch tracking

-- | Mark a trigger as being worked on.  Call at dispatch entry, before
-- any of the slow prologue that runs ahead of 'registerTask'.
beginDispatch :: TaskRegistry -> GroupId -> MessageId -> IO ()
beginDispatch reg gid (MessageId mid) =
  atomically $
    modifyTVar' reg.trPending (Map.insertWith Set.union gid (Set.singleton mid))

-- | Release it.  Belongs in the same @finally@ that releases the
-- shutdown slot; a leak here would make a finished question look
-- permanently in-flight to every later turn.
endDispatch :: TaskRegistry -> GroupId -> MessageId -> IO ()
endDispatch reg gid (MessageId mid) =
  atomically $ modifyTVar' reg.trPending (Map.update drop' gid)
  where
    drop' s =
      let s' = Set.delete mid s
       in if Set.null s' then Nothing else Just s'

-- | Trigger ids in @gid@ that some other turn is already handling.
-- 'Max.Prompt.buildContext' uses this to stop a concurrent dispatch
-- answering a question that is already being answered.
inFlightTriggers :: TaskRegistry -> GroupId -> IO (Set Int64)
inFlightTriggers reg gid =
  Map.findWithDefault Set.empty gid <$> readTVarIO reg.trPending

listTasks :: TaskRegistry -> Maybe GroupId -> IO [TaskInfo]
listTasks reg mGid = do
  entries <- atomically $ do
    m <- readTVar reg.trMap
    pure $ case mGid of
      Just gid -> Map.elems (Map.filter (\e -> e.teGroup == gid) m)
      Nothing -> Map.elems m
  traverse toInfo (sortOn teStartedAt entries)
  where
    toInfo e = do
      pending <- length <$> readTVarIO e.teInbox
      pure
        TaskInfo
          { tiId = e.teId,
            tiGroup = e.teGroup,
            tiUser = e.teUser,
            tiKind = e.teKind,
            tiStartedAt = e.teStartedAt,
            tiPendingBtw = pending
          }

-- | Trigger the cancel action for one task.  Returns 'False' if the
-- id is unknown (e.g. the task already finished).  Does NOT remove
-- the entry — the producer's @bracket@ does that on the way out.
cancelTask :: TaskRegistry -> TaskId -> IO Bool
cancelTask reg tid = do
  mEntry <- atomically $ do
    m <- readTVar reg.trMap
    pure (Map.lookup tid m)
  case mEntry of
    Just e -> e.teCancel >> pure True
    Nothing -> pure False

-- | Trigger the cancel action for every registered task (all groups —
-- same scope as @!ps --all@).  Returns how many were signalled.
-- Snapshot first, then fire: a cancel action unregisters its entry
-- via the producer's @bracket@, and we must not mutate under the fold.
cancelAllTasks :: TaskRegistry -> IO Int
cancelAllTasks reg = do
  entries <- Map.elems <$> readTVarIO reg.trMap
  mapM_ (.teCancel) entries
  pure (length entries)
