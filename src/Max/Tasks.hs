-- |
-- In-flight task registry, scoped per bot process.  Tasks correspond
-- 1:1 to agent dispatches (one per @-mention that triggers the LLM
-- path).  Lost on restart by design — tasks are by definition
-- ephemeral work-in-progress.
--
-- Each task carries a 'btwInbox' 'TVar' the agent loop drains between
-- turns; @!btw@ pushes into the latest task's inbox.  @!ps@ enumerates
-- them; @!kill@ throws a 'TaskCancelled' exception into the task's
-- thread (the agent's @bracket@ unregisters cleanly on the way out).
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
    -- * Operations
    TaskInfo (..),
    listTasks,
    cancelTask,
    drainBtwInbox,
    pushBtwToLatest,
    -- * Exception
    TaskCancelled (..),
  )
where

import Control.Concurrent.STM
import Control.Exception (Exception)
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Ord (Down (..))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime, getCurrentTime)
import OneBot.Types (GroupId (..))

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
    tiKind :: !Text,
    tiStartedAt :: !UTCTime,
    -- | Notes currently pending in the inbox (useful to see whether
    -- the user's @!btw@ landed).
    tiPendingBtw :: !Int
  }
  deriving stock (Show)

data TaskRegistry = TaskRegistry
  { trNextId :: !(TVar Int),
    trMap :: !(TVar (Map TaskId TaskEntry))
  }

newTaskRegistry :: IO TaskRegistry
newTaskRegistry = TaskRegistry <$> newTVarIO 0 <*> newTVarIO Map.empty

-- | Custom exception so we can distinguish a user-initiated @!kill@
-- from generic 'ThreadKilled' / shutdown.  The agent's @bracket@
-- catches it for the unregister side; 'catchSync' lets it propagate
-- (we want @!kill@ to actually kill the task, not just log-and-retry).
data TaskCancelled = TaskCancelled
  deriving stock (Show)

instance Exception TaskCancelled

--------------------------------------------------------------------------------
-- Lifecycle

registerTask ::
  TaskRegistry ->
  GroupId ->
  -- | Kind label shown in @!ps@; "llm" / "search" / etc.
  Text ->
  -- | Cancel action; runs when 'cancelTask' targets this entry.
  IO () ->
  IO TaskHandle
registerTask reg gid kind cancel = do
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

-- | Append a note to the most-recently-started task in @gid@'s inbox.
-- Returns 'False' if the group has no active task.
pushBtwToLatest :: TaskRegistry -> GroupId -> Text -> IO Bool
pushBtwToLatest reg gid note = atomically $ do
  m <- readTVar reg.trMap
  let inGroup = Map.elems (Map.filter (\e -> e.teGroup == gid) m)
  case sortOn (Down . teStartedAt) inGroup of
    [] -> pure False
    (latest : _) -> do
      modifyTVar' latest.teInbox (<> [note])
      pure True

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
