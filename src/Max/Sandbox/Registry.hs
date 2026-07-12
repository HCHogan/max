-- |
-- In-memory sandbox registry, scoped per process.  Sandboxes are
-- owned by a 'GroupId' (== session); they persist across multiple
-- agent dispatches in the same group's session and are destroyed
-- only by an explicit @sandbox_destroy@ call, @!clear --all@, or bot
-- exit.  Lost on restart by design — the bot is the gatekeeper of
-- the @max-sb-*@ docker namespace, so on startup we reap any
-- leftover containers from a previous run that didn't shut down
-- cleanly.
--
-- == Concurrency
--
-- Multiple agent dispatches in the same session can hit the same
-- sandbox in parallel.  Each 'SandboxEntry' carries a 'TMVar' exec
-- lock so 'execInSandbox' serializes against itself; @docker exec@
-- still spawns independent processes inside the container, so we
-- pick the lock granularity to be the natural one: "one shell at a
-- time per sandbox".
--
-- File-system races (same path written by two parallel calls) are
-- outside the lock's scope — that's a user-level coordination
-- problem.  Tool descriptions advertise this so the model knows
-- sandboxes are shared within a group.
module Max.Sandbox.Registry
  ( -- * Registry
    SandboxRegistry,
    newSandboxRegistry,
    reapStaleSandboxes,
    -- * Entries
    SandboxId (..),
    SandboxEntry (..),
    SandboxCreateOpts (..),
    defaultCreateOpts,
    -- * Operations
    createSandbox,
    listSandboxesForGroup,
    listSandbox,
    execInSandbox,
    readSandboxFile,
    writeSandboxFile,
    destroySandbox,
    destroySandboxesForGroup,
    destroyAllSandboxes,
    -- * Naming
    namePrefix,
  )
where

import Control.Concurrent.STM
import Control.Exception (bracket_)
import Control.Monad (when)
import Data.Foldable (for_)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime, getCurrentTime)
import Max.Sandbox.Docker
  ( ExecResult (..),
    listContainersByPrefix,
    listVolumesByPrefix,
    runExec,
    runRead,
    runRm,
    runRun,
    runVolumeRm,
    runWrite,
  )
import OneBot.Types (GroupId (..))

-- | All container/volume names start here; we own the namespace,
-- and use it both to find our own resources and to reap stale ones
-- on boot.
namePrefix :: Text
namePrefix = "max-sb-"

-- | Short, human-typeable id like @s7@.  Counter is process-wide.
newtype SandboxId = SandboxId {unSandboxId :: Text}
  deriving stock (Show, Eq, Ord)

data SandboxEntry = SandboxEntry
  { seId :: !SandboxId,
    seGroup :: !GroupId,
    seContainer :: !Text,
    seVolume :: !Text,
    seImage :: !Text,
    seCreatedAt :: !UTCTime,
    -- | Serializes 'execInSandbox' on this sandbox.
    seExecLock :: !(TMVar ())
  }

data SandboxRegistry = SandboxRegistry
  { srNextId :: !(TVar Int),
    srEntries :: !(TVar (Map SandboxId SandboxEntry))
  }

newSandboxRegistry :: IO SandboxRegistry
newSandboxRegistry =
  SandboxRegistry <$> newTVarIO 0 <*> newTVarIO Map.empty

-- | Best-effort cleanup of containers/volumes from a previous run
-- that crashed before its bracket released.  Run once at startup,
-- before any sandboxes are created.
reapStaleSandboxes :: IO ()
reapStaleSandboxes = do
  cs <- listContainersByPrefix namePrefix
  for_ cs runRm
  vs <- listVolumesByPrefix namePrefix
  for_ vs runVolumeRm

--------------------------------------------------------------------------------
-- Create options.

data SandboxCreateOpts = SandboxCreateOpts
  { scoImage :: !Text,
    scoNetwork :: !Text
  }
  deriving stock (Show)

-- | Default image is the nix-enabled base built from
-- @sandbox-image/@ (@build.sh@ must have been run on the docker
-- host); packages come from the pinned nixpkgs via @nix shell@,
-- with the store shared across sandboxes through 'nixVolume'.
defaultCreateOpts :: SandboxCreateOpts
defaultCreateOpts =
  SandboxCreateOpts
    { scoImage = "max-sandbox:latest",
      scoNetwork = "bridge"
    }

--------------------------------------------------------------------------------
-- Create.

createSandbox ::
  SandboxRegistry ->
  GroupId ->
  SandboxCreateOpts ->
  IO (Either Text SandboxEntry)
createSandbox reg gid opts = do
  now <- getCurrentTime
  -- Allocate the id + tentative entry first so the name is unique
  -- before we hit docker.
  (sid, container, volume, lock) <- atomically $ do
    n <- readTVar reg.srNextId
    writeTVar reg.srNextId (n + 1)
    let sid = SandboxId ("s" <> T.pack (show (n + 1)))
        GroupId rawGid = gid
        nameBody = T.pack (show rawGid) <> "-" <> sid.unSandboxId
        container = namePrefix <> nameBody
        volume = namePrefix <> nameBody <> "-data"
    lock <- newTMVar ()
    pure (sid, container, volume, lock)
  res <-
    runRun
      container
      opts.scoImage
      volume
      opts.scoNetwork
  case res of
    Left err -> do
      -- docker run failed; nothing to clean (no container created),
      -- but volume may have been auto-created on the way.  Best-effort.
      runVolumeRm volume
      pure (Left err)
    Right _cid -> do
      let entry =
            SandboxEntry
              { seId = sid,
                seGroup = gid,
                seContainer = container,
                seVolume = volume,
                seImage = opts.scoImage,
                seCreatedAt = now,
                seExecLock = lock
              }
      atomically $ modifyTVar' reg.srEntries (Map.insert sid entry)
      pure (Right entry)

--------------------------------------------------------------------------------
-- Lookup.

listSandboxesForGroup :: SandboxRegistry -> GroupId -> IO [SandboxEntry]
listSandboxesForGroup reg gid = do
  m <- readTVarIO reg.srEntries
  pure $ filter (\e -> e.seGroup == gid) (Map.elems m)

-- | Look up one sandbox by id, but only if it belongs to the given
-- group.  Wrong-group requests get 'Nothing' (so we don't leak
-- cross-group sandbox ids).
listSandbox :: SandboxRegistry -> GroupId -> SandboxId -> IO (Maybe SandboxEntry)
listSandbox reg gid sid = do
  m <- readTVarIO reg.srEntries
  pure $ case Map.lookup sid m of
    Just e | e.seGroup == gid -> Just e
    _ -> Nothing

--------------------------------------------------------------------------------
-- Exec.

-- | Run a shell command in a group's sandbox.  Serialised per
-- sandbox via 'seExecLock'; concurrent calls queue up.  Wrong-group
-- ids return 'Left'.
execInSandbox ::
  SandboxRegistry ->
  GroupId ->
  SandboxId ->
  Text ->
  Int ->
  IO (Either Text ExecResult)
execInSandbox reg gid sid cmd timeoutSecs = do
  mEntry <- listSandbox reg gid sid
  case mEntry of
    Nothing -> pure (Left "sandbox not found")
    Just e ->
      bracket_
        (atomically $ takeTMVar e.seExecLock)
        (atomically $ putTMVar e.seExecLock ())
        (Right <$> runExec e.seContainer cmd timeoutSecs)

readSandboxFile ::
  SandboxRegistry ->
  GroupId ->
  SandboxId ->
  Text ->
  Int ->
  IO (Either Text Text)
readSandboxFile reg gid sid path maxBytes = do
  mEntry <- listSandbox reg gid sid
  case mEntry of
    Nothing -> pure (Left "sandbox not found")
    Just e ->
      bracket_
        (atomically $ takeTMVar e.seExecLock)
        (atomically $ putTMVar e.seExecLock ())
        (runRead e.seContainer path maxBytes)

writeSandboxFile ::
  SandboxRegistry ->
  GroupId ->
  SandboxId ->
  Text ->
  Text ->
  IO (Either Text ())
writeSandboxFile reg gid sid path content = do
  mEntry <- listSandbox reg gid sid
  case mEntry of
    Nothing -> pure (Left "sandbox not found")
    Just e ->
      bracket_
        (atomically $ takeTMVar e.seExecLock)
        (atomically $ putTMVar e.seExecLock ())
        (runWrite e.seContainer path content)

--------------------------------------------------------------------------------
-- Destroy.

destroySandbox ::
  SandboxRegistry ->
  GroupId ->
  SandboxId ->
  IO (Either Text ())
destroySandbox reg gid sid = do
  mEntry <- listSandbox reg gid sid
  case mEntry of
    Nothing -> pure (Left "sandbox not found")
    Just e -> do
      atomically $ modifyTVar' reg.srEntries (Map.delete sid)
      runRm e.seContainer
      runVolumeRm e.seVolume
      pure (Right ())

-- | Destroy every sandbox owned by @gid@.  Returns count destroyed.
-- Used by @!clear --all@.
destroySandboxesForGroup :: SandboxRegistry -> GroupId -> IO Int
destroySandboxesForGroup reg gid = do
  entries <- atomically $ do
    m <- readTVar reg.srEntries
    let (mine, rest) = Map.partition (\e -> e.seGroup == gid) m
    writeTVar reg.srEntries rest
    pure (Map.elems mine)
  for_ entries $ \e -> do
    runRm e.seContainer
    runVolumeRm e.seVolume
  pure (length entries)

-- | Tear down every sandbox.  Used by the top-level bracket in
-- @main@ on bot exit (clean shutdown or async exception).
destroyAllSandboxes :: SandboxRegistry -> IO ()
destroyAllSandboxes reg = do
  entries <- atomically $ do
    m <- readTVar reg.srEntries
    writeTVar reg.srEntries Map.empty
    pure (Map.elems m)
  when (not (null entries)) $ pure ()
  for_ entries $ \e -> do
    runRm e.seContainer
    runVolumeRm e.seVolume
