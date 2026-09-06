-- |
-- Durable sandbox registry.  PostgreSQL owns lifecycle metadata and each
-- named Docker volume owns the live filesystem; the STM map is only a cache
-- and per-sandbox lock table.  Production boot reconciles rows with Docker,
-- adopting a live container or rebuilding it around a surviving volume.
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
    newDurableSandboxRegistry,
    reapStaleSandboxes,
    reconcileSandboxes,
    gcExpiredSandboxes,

    -- * Entries
    SandboxId (..),
    SandboxEntry (..),
    SandboxCreateOpts (..),
    defaultCreateOpts,

    -- * Operations
    createSandbox,
    ensureSandbox,
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
import Control.Monad (void, when)
import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.Foldable (for_)
import Data.Int (Int64)
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (listToMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (NominalDiffTime, UTCTime, addUTCTime, getCurrentTime)
import Database.PostgreSQL.Simple (Only (..), execute, query, withTransaction)
import Max.Concurrent.Lock (withLock)
import Max.DB.Connection (DbPool, withConn)
import Max.Sandbox.Docker
  ( DockerContainerStatus (..),
    DockerPresence (..),
    ExecResult (..),
    inspectContainerPolicy,
    inspectContainerStatus,
    inspectVolumePresence,
    listContainersByPrefix,
    listVolumesByPrefix,
    runExec,
    runPreparePackages,
    runRead,
    runRm,
    runRun,
    runVolumeRm,
    runWrite,
    wrapPackages,
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
    seNetwork :: !Text,
    seCreatedAt :: !UTCTime,
    -- | Serializes 'execInSandbox' on this sandbox.
    seExecLock :: !(TMVar ())
  }

data SandboxRegistry = SandboxRegistry
  { srNextId :: !(TVar Int),
    srEntries :: !(TVar (Map SandboxId SandboxEntry)),
    srDbPool :: !(Maybe DbPool)
  }

newSandboxRegistry :: IO SandboxRegistry
newSandboxRegistry =
  SandboxRegistry <$> newTVarIO 0 <*> newTVarIO Map.empty <*> pure Nothing

newDurableSandboxRegistry :: DbPool -> IO SandboxRegistry
newDurableSandboxRegistry pool = do
  registry <- SandboxRegistry <$> newTVarIO 0 <*> newTVarIO Map.empty <*> pure (Just pool)
  reconcileSandboxes registry
  pure registry

-- | Best-effort cleanup of containers/volumes from a previous run
-- that crashed before its bracket released.  Run once at startup,
-- before any sandboxes are created.
reapStaleSandboxes :: IO ()
reapStaleSandboxes = do
  cs <- listContainersByPrefix namePrefix
  for_ cs runRm
  vs <- listVolumesByPrefix namePrefix
  for_ vs runVolumeRm

data PersistedSandbox = PersistedSandbox
  { psId :: !Int64,
    psGroup :: !Int64,
    psHandle :: !Text,
    psContainer :: !Text,
    psVolume :: !Text,
    psImage :: !Text,
    psNetwork :: !Text,
    psCreatedAt :: !UTCTime,
    psExpiresAt :: !UTCTime
  }

-- | Reconcile database rows against external resources.  A volume is the
-- durable unit: if it survives but the container does not, rebuild the
-- container around it; if the volume is gone, mark the row destroyed.  Names
-- in Max's namespace with no database owner are pre-E0/orphan resources and
-- are reclaimed.
reconcileSandboxes :: SandboxRegistry -> IO ()
reconcileSandboxes reg = case reg.srDbPool of
  Nothing -> pure ()
  Just pool -> do
    now <- getCurrentTime
    rows <- loadPersisted pool
    containers <- Set.fromList <$> listContainersByPrefix namePrefix
    volumes <- Set.fromList <$> listVolumesByPrefix namePrefix
    let knownContainers = Set.fromList (map (.psContainer) rows)
        knownVolumes = Set.fromList (map (.psVolume) rows)
    for_ rows $ \row ->
      if row.psExpiresAt <= now
        then void (destroyPersisted reg row)
        else do
          -- Namespace listings are only an orphan-cleanup optimization.  A
          -- persisted row is destroyed only after a per-resource inspection
          -- positively reports absence; daemon/CLI failure is not absence.
          volumeState <- inspectVolumePresence row.psVolume
          case volumeState of
            DockerAbsent -> do
              runRm row.psContainer
              atomically $ modifyTVar' reg.srEntries (Map.delete (SandboxId row.psHandle))
              markSandboxDestroyed pool row.psId "durable volume missing during boot reconciliation"
            DockerUnavailable detail ->
              markSandboxUnknown pool row.psId detail
            DockerPresent -> do
              containerState <- inspectContainerStatus row.psContainer
              case containerState of
                DockerContainerRunning -> do
                  currentPolicy <- inspectContainerPolicy row.psContainer
                  if currentPolicy && persistedPolicyCurrent row
                    then adoptPersisted reg pool row
                    else rebuildPersisted reg pool row
                DockerContainerStopped -> rebuildPersisted reg pool row
                DockerContainerMissing -> rebuildPersisted reg pool row
                DockerContainerUnavailable detail ->
                  markSandboxUnknown pool row.psId detail
    for_ (Set.toList (containers `Set.difference` knownContainers)) runRm
    for_ (Set.toList (volumes `Set.difference` knownVolumes)) runVolumeRm

gcExpiredSandboxes :: SandboxRegistry -> IO Int
gcExpiredSandboxes reg = case reg.srDbPool of
  Nothing -> pure 0
  Just pool -> do
    now <- getCurrentTime
    rows <- filter ((<= now) . (.psExpiresAt)) <$> loadPersisted pool
    outcomes <- traverse (destroyPersisted reg) rows
    pure (length (filter id outcomes))

adoptPersisted :: SandboxRegistry -> DbPool -> PersistedSandbox -> IO ()
adoptPersisted reg pool row = do
  entry <- entryFromPersisted row
  -- Hourly reconciliation must not replace the per-sandbox lock while an
  -- exec is holding it.  Keep the live cache entry when present; a fresh one
  -- is needed only on boot or after this process has evicted the sandbox.
  atomically (modifyTVar' reg.srEntries (Map.insertWith (\_ old -> old) entry.seId entry))
  markSandboxActive pool row.psId

rebuildPersisted :: SandboxRegistry -> DbPool -> PersistedSandbox -> IO ()
rebuildPersisted reg pool row = do
  let secured = securePersisted row
  -- A stopped/dead container still owns its name.  The volume is the durable
  -- state, so discard only the shell and recreate it around that volume.
  runRm row.psContainer
  updateSandboxRuntime pool secured
  runRun secured.psContainer secured.psImage secured.psVolume secured.psNetwork >>= \case
    Right _ -> adoptPersisted reg pool secured
    Left detail -> markSandboxUnknown pool row.psId detail

--------------------------------------------------------------------------------
-- Create options.

data SandboxCreateOpts = SandboxCreateOpts
  { scoImage :: !Text,
    scoNetwork :: !Text
  }
  deriving stock (Show)

-- | Default image is the nix-enabled base built from
-- @sandbox-image/@ (@build.sh@ must have been run on the docker
-- host); packages come from pinned nixpkgs store paths realised by a
-- restricted helper, with the store shared through 'nixVolume'.
defaultCreateOpts :: SandboxCreateOpts
defaultCreateOpts =
  SandboxCreateOpts
    { scoImage = "max-sandbox:latest",
      scoNetwork = "none"
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
  -- Image and network are operator policy, never model-selected authority.
  -- Keep the argument for the internal API shape, but normalize it here so a
  -- future caller cannot accidentally re-open the old escape hatch.
  let securedOpts = opts {scoImage = defaultCreateOpts.scoImage, scoNetwork = defaultCreateOpts.scoNetwork}
  allocated <- allocateSandbox reg gid securedOpts now
  let (dbId, sid, container, volume) = allocated
  lock <- newTMVarIO ()
  let entry =
        SandboxEntry
          { seId = sid,
            seGroup = gid,
            seContainer = container,
            seVolume = volume,
            seImage = securedOpts.scoImage,
            seNetwork = securedOpts.scoNetwork,
            seCreatedAt = now,
            seExecLock = lock
          }
  launched <- runRun container securedOpts.scoImage volume securedOpts.scoNetwork
  case launched of
    Left err -> do
      for_ reg.srDbPool $ \pool -> markSandboxUnknown pool dbId err
      pure (Left err)
    Right _ -> do
      for_ reg.srDbPool $ \pool -> markSandboxActive pool dbId
      atomically $ modifyTVar' reg.srEntries (Map.insert sid entry)
      pure (Right entry)

-- | The group's default sandbox for user-facing @! \<cmd\>@ shell
-- commands: reuse the group's existing sandbox if it has one (the
-- lowest-id entry, for stability), otherwise spin one up with
-- 'defaultCreateOpts'.  The model's own @sandbox_create@ flow is
-- unaffected — it always makes a fresh, explicitly-managed sandbox.
ensureSandbox :: SandboxRegistry -> GroupId -> IO (Either Text SandboxEntry)
ensureSandbox reg gid = do
  existing <- listSandboxesForGroup reg gid
  case listToMaybe (sortOn (.seId) existing) of
    Just e -> pure (Right e)
    Nothing -> createSandbox reg gid defaultCreateOpts

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
  case Map.lookup sid m of
    Just e | e.seGroup == gid -> do
      touchSandbox reg e
      pure (Just e)
    _ -> pure Nothing

--------------------------------------------------------------------------------
-- Exec.

-- | Run a shell command in a group's sandbox.  Serialised per
-- sandbox via 'seExecLock'; concurrent calls queue up.  Wrong-group
-- ids return 'Left'.
execInSandbox ::
  SandboxRegistry ->
  GroupId ->
  SandboxId ->
  -- | nixpkgs attributes realised by the restricted package helper
  [Text] ->
  Text ->
  Int ->
  IO (Either Text ExecResult)
execInSandbox reg gid sid packages cmd timeoutSecs = do
  if length packages > maxPackageAttributes
    then pure (Left "too many nixpkgs attributes (maximum 32)")
    else
      if not (all validNixAttribute packages)
        then pure (Left "invalid nixpkgs attribute (allowed: letters, digits, '.', '_', '+', '-', non-empty path segments, at most 128 characters)")
        else run
  where
    run = do
      mEntry <- listSandbox reg gid sid
      case mEntry of
        Nothing -> pure (Left "sandbox not found")
        Just e ->
          withLock
            e.seExecLock
            ( do
                prepared <- runPreparePackages e.seImage packages timeoutSecs
                case prepared of
                  Left detail -> pure (Left detail)
                  Right storePaths -> do
                    result <- runExec e.seContainer e.seNetwork (wrapPackages storePaths cmd) timeoutSecs
                    -- @-1@ is reserved for failure to invoke Docker itself.  For a
                    -- write-capable tool this must travel as Left so the tool kernel
                    -- records outcome-unknown, never as a seemingly committed shell
                    -- exit code.  Ordinary in-container non-zero exits remain rich
                    -- committed results because the command may have mutated state.
                    pure $
                      if result.erExitCode == -1
                        then Left result.erStderr
                        else Right result
            )

maxPackageAttributes :: Int
maxPackageAttributes = 32

validNixAttribute :: Text -> Bool
validNixAttribute attr =
  not (T.null attr)
    && T.length attr <= 128
    && not (any T.null (T.splitOn "." attr))
    && T.all allowed attr
  where
    allowed c =
      isAsciiLower c
        || isAsciiUpper c
        || isDigit c
        || c `elem` ("._+-" :: String)

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
      withLock
        e.seExecLock
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
      withLock
        e.seExecLock
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
    Just e -> releaseSandbox reg e

-- | Destroy every sandbox owned by @gid@.  Returns count destroyed.
-- Used by @!clear --all@.
destroySandboxesForGroup :: SandboxRegistry -> GroupId -> IO Int
destroySandboxesForGroup reg gid = do
  entries <- filter ((== gid) . (.seGroup)) . Map.elems <$> readTVarIO reg.srEntries
  results <- traverse (releaseSandbox reg) entries
  pure (length [() | Right () <- results])

-- | Tear down every sandbox explicitly.  Production shutdown intentionally
-- does not call this: durable volumes survive process lifetime.
destroyAllSandboxes :: SandboxRegistry -> IO ()
destroyAllSandboxes reg = do
  entries <- Map.elems <$> readTVarIO reg.srEntries
  for_ entries (void . releaseSandbox reg)

-- The exec lock keeps destruction from racing an in-container operation.
-- Once destruction begins, the cache entry is removed even if Docker becomes
-- unavailable; the durable row remains outcome-unknown for reconciliation.
releaseSandbox :: SandboxRegistry -> SandboxEntry -> IO (Either Text ())
releaseSandbox reg entry =
  withLock entry.seExecLock $
    do
      for_ reg.srDbPool $ \pool -> markSandboxDestroying pool entry.seId
      cleaned <- cleanupSandbox entry
      atomically $ modifyTVar' reg.srEntries (Map.delete entry.seId)
      case cleaned of
        Right () -> do
          for_ reg.srDbPool $ \pool -> markSandboxDestroyedByHandle pool entry.seId "explicit destroy"
          pure (Right ())
        Left detail -> do
          for_ reg.srDbPool $ \pool -> markSandboxUnknownByHandle pool entry.seId detail
          pure (Left "sandbox volume cleanup failed; state retained for reconciliation")

cleanupSandbox :: SandboxEntry -> IO (Either Text ())
cleanupSandbox entry = do
  runRm entry.seContainer
  runVolumeRm entry.seVolume
  inspectVolumePresence entry.seVolume >>= \case
    DockerAbsent -> pure (Right ())
    DockerPresent -> pure (Left "volume cleanup failed; durable volume still exists")
    DockerUnavailable detail -> pure (Left ("destruction outcome unknown: " <> detail))

--------------------------------------------------------------------------------
-- Durable metadata helpers.

allocateSandbox ::
  SandboxRegistry ->
  GroupId ->
  SandboxCreateOpts ->
  UTCTime ->
  IO (Int64, SandboxId, Text, Text)
allocateSandbox reg (GroupId rawGroup) opts now = case reg.srDbPool of
  Nothing -> atomically $ do
    n <- readTVar reg.srNextId
    writeTVar reg.srNextId (n + 1)
    let ordinal = n + 1
        sid = SandboxId ("s" <> T.pack (show ordinal))
        nameBody = T.pack (show rawGroup) <> "-" <> sid.unSandboxId
    pure (0, sid, namePrefix <> nameBody, namePrefix <> nameBody <> "-data")
  Just pool -> withConn pool $ \conn -> withTransaction conn $ do
    conversationRows <-
      query conn "SELECT conversation_id FROM conversations WHERE legacy_group_id = ? FOR UPDATE" (Only rawGroup)
    conversation <- case conversationRows :: [Only Int64] of
      [Only value] -> pure value
      _ -> fail "allocateSandbox: conversation not found"
    idRows <- query conn "SELECT nextval('sandboxes_sandbox_id_seq')" ()
    dbId <- case idRows :: [Only Int64] of
      [Only value] -> pure value
      _ -> fail "allocateSandbox: sequence did not return one row"
    let sid = SandboxId ("s" <> T.pack (show dbId))
        nameBody = T.pack (show rawGroup) <> "-" <> sid.unSandboxId
        container = namePrefix <> nameBody
        volume = namePrefix <> nameBody <> "-data"
        expiry = addUTCTime sandboxTtl now
    inserted <-
      execute
        conn
        "INSERT INTO sandboxes \
        \ (sandbox_id, conversation_id, sandbox_handle, container_name, volume_name, image, network_mode, \
        \  status, created_at, last_used_at, expires_at) \
        \ VALUES (?, ?, ?, ?, ?, ?, ?, 'creating', ?, ?, ?)"
        (dbId, conversation, sid.unSandboxId, container, volume, opts.scoImage, opts.scoNetwork, now, now, expiry)
    when (inserted /= 1) (fail "allocateSandbox: insert did not affect one row")
    pure (dbId, sid, container, volume)

sandboxTtl :: NominalDiffTime
sandboxTtl = 14 * 24 * 60 * 60

loadPersisted :: DbPool -> IO [PersistedSandbox]
loadPersisted pool = withConn pool $ \conn -> do
  rows <-
    query
      conn
      "SELECT sb.sandbox_id, c.legacy_group_id, sb.sandbox_handle, sb.container_name, \
      \       sb.volume_name, sb.image, sb.network_mode, sb.created_at, sb.expires_at \
      \ FROM sandboxes sb JOIN conversations c USING (conversation_id) \
      \ WHERE sb.status <> 'destroyed' ORDER BY sb.sandbox_id"
      ()
  pure
    [ PersistedSandbox dbId groupId handle container volume image network created expires
    | (dbId, groupId, handle, container, volume, image, network, created, expires) <-
        (rows :: [(Int64, Int64, Text, Text, Text, Text, Text, UTCTime, UTCTime)])
    ]

entryFromPersisted :: PersistedSandbox -> IO SandboxEntry
entryFromPersisted row = do
  lock <- newTMVarIO ()
  pure
    SandboxEntry
      { seId = SandboxId row.psHandle,
        seGroup = GroupId row.psGroup,
        seContainer = row.psContainer,
        seVolume = row.psVolume,
        seImage = row.psImage,
        seNetwork = row.psNetwork,
        seCreatedAt = row.psCreatedAt,
        seExecLock = lock
      }

persistedPolicyCurrent :: PersistedSandbox -> Bool
persistedPolicyCurrent row =
  row.psImage == defaultCreateOpts.scoImage
    && row.psNetwork == defaultCreateOpts.scoNetwork

securePersisted :: PersistedSandbox -> PersistedSandbox
securePersisted row =
  row
    { psImage = defaultCreateOpts.scoImage,
      psNetwork = defaultCreateOpts.scoNetwork
    }

updateSandboxRuntime :: DbPool -> PersistedSandbox -> IO ()
updateSandboxRuntime pool row = withConn pool $ \conn -> do
  _ <-
    execute
      conn
      "UPDATE sandboxes SET image = ?, network_mode = ? WHERE sandbox_id = ?"
      (row.psImage, row.psNetwork, row.psId)
  pure ()

touchSandbox :: SandboxRegistry -> SandboxEntry -> IO ()
touchSandbox reg entry = for_ reg.srDbPool $ \pool -> withConn pool $ \conn -> do
  _ <-
    execute
      conn
      "UPDATE sandboxes SET last_used_at = now(), expires_at = now() + interval '14 days' \
      \ WHERE sandbox_handle = ? AND status = 'active'"
      (Only entry.seId.unSandboxId)
  pure ()

markSandboxActive :: DbPool -> Int64 -> IO ()
markSandboxActive pool dbId = withConn pool $ \conn -> do
  _ <- execute conn "UPDATE sandboxes SET status = 'active', failure_detail = NULL WHERE sandbox_id = ?" (Only dbId)
  pure ()

markSandboxUnknown :: DbPool -> Int64 -> Text -> IO ()
markSandboxUnknown pool dbId detail = withConn pool $ \conn -> do
  _ <-
    execute
      conn
      "UPDATE sandboxes SET status = 'outcome-unknown', failure_detail = ? WHERE sandbox_id = ?"
      (T.take 4000 detail, dbId)
  pure ()

markSandboxUnknownByHandle :: DbPool -> SandboxId -> Text -> IO ()
markSandboxUnknownByHandle pool sid detail = withConn pool $ \conn -> do
  _ <-
    execute
      conn
      "UPDATE sandboxes SET status = 'outcome-unknown', failure_detail = ? WHERE sandbox_handle = ?"
      (T.take 4000 detail, sid.unSandboxId)
  pure ()

markSandboxDestroying :: DbPool -> SandboxId -> IO ()
markSandboxDestroying pool sid = withConn pool $ \conn -> do
  _ <- execute conn "UPDATE sandboxes SET status = 'destroying' WHERE sandbox_handle = ? AND status <> 'destroyed'" (Only sid.unSandboxId)
  pure ()

markSandboxDestroyedByHandle :: DbPool -> SandboxId -> Text -> IO ()
markSandboxDestroyedByHandle pool sid detail = withConn pool $ \conn -> do
  _ <-
    execute
      conn
      "UPDATE sandboxes SET status = 'destroyed', destroyed_at = now(), failure_detail = ? WHERE sandbox_handle = ?"
      (detail, sid.unSandboxId)
  pure ()

markSandboxDestroyed :: DbPool -> Int64 -> Text -> IO ()
markSandboxDestroyed pool dbId detail = withConn pool $ \conn -> do
  _ <-
    execute
      conn
      "UPDATE sandboxes SET status = 'destroyed', destroyed_at = now(), failure_detail = ? WHERE sandbox_id = ?"
      (detail, dbId)
  pure ()

destroyPersisted :: SandboxRegistry -> PersistedSandbox -> IO Bool
destroyPersisted reg row = do
  let sid = SandboxId row.psHandle
      cleanup pool = do
        markSandboxDestroying pool sid
        runRm row.psContainer
        runVolumeRm row.psVolume
        atomically $ modifyTVar' reg.srEntries (Map.delete sid)
        inspectVolumePresence row.psVolume >>= \case
          DockerAbsent -> markSandboxDestroyed pool row.psId "sandbox TTL expired" >> pure True
          DockerPresent -> markSandboxUnknown pool row.psId "TTL cleanup failed; durable volume still exists" >> pure False
          DockerUnavailable detail -> markSandboxUnknown pool row.psId ("TTL destruction outcome unknown: " <> detail) >> pure False
      withEntryLock action = do
        entries <- readTVarIO reg.srEntries
        case Map.lookup sid entries of
          Nothing -> action
          Just entry ->
            withLock
              entry.seExecLock
              action
  case reg.srDbPool of
    Nothing -> pure False
    Just pool -> withEntryLock (cleanup pool)
