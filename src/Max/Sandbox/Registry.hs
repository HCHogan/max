-- | Persist sandbox metadata and work directories; cache handles and locks in STM.
-- Boot adopts live containers or rebuilds them around retained volumes. Lifecycle
-- changes stop admission and drain users; callers coordinate concurrent file/port use.
-- A (re)created sandbox has its conversation's /chat view backfilled.
module Max.Sandbox.Registry
  ( -- * Registry
    SandboxRegistry,
    ChatViewBackfill,
    newDurableSandboxRegistry,
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
    readSandboxBytes,
    destroySandbox,
    destroySandboxesForGroup,

    -- * Naming
    namePrefix,
  )
where

import Control.Concurrent.STM
import Control.Monad (void, when)
import Data.ByteString qualified as BS
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
import Data.Time
  ( NominalDiffTime,
    UTCTime,
    addUTCTime,
    getCurrentTime,
  )
import Database.PostgreSQL.Simple
  ( Only (..),
    execute,
    query,
    withTransaction,
  )
import Max.Concurrent.Lock
  ( LockMap,
    SharedLock,
    newLockMap,
    newSharedLock,
    withExclusiveLock,
    withKeyLock,
    withLock,
    withSharedLock,
  )
import Max.DB.Connection (DbPool, withConn)
import Max.Sandbox.Runtime
  ( ExecResult (..),
    RuntimeContainerStatus (..),
    RuntimePresence (..),
    classifyRead,
    inspectContainerPolicy,
    inspectContainerStatus,
    inspectVolumePresence,
    listContainersByPrefix,
    listVolumesByPrefix,
    networkForGroup,
    readSandboxArtifact,
    runExec,
    runPreparePackages,
    runReadPrefix,
    runRm,
    runRun,
    runVolumeRm,
    runWrite,
    sandboxNetwork,
    wrapPackages,
  )
import Max.Sandbox.Types (SandboxId (..), SandboxRead)
import OneBot.Types (GroupId (..))

-- | All container/volume names start here; we own the namespace,
-- and use it both to find our own resources and to reap stale ones
-- on boot.
namePrefix :: Text
namePrefix = "max-sb-"

-- | Short, human-typeable id like @s7@.  Allocated by the durable database sequence.
data SandboxEntry = SandboxEntry
  { seId :: !SandboxId,
    seGroup :: !GroupId,
    seContainer :: !Text,
    seVolume :: !Text,
    seImage :: !Text,
    seNetwork :: !Text,
    seCreatedAt :: !UTCTime,
    -- | Shared command access and exclusive lifecycle transitions.
    seAccess :: !SharedLock,
    -- | Short readiness checks; never held while executing the user command.
    sePrepareLock :: !(TMVar ())
  }

-- | Link a conversation's existing media into the /chat view the broker has
-- just created or re-bound. Ingest links later media as they arrive. Supplied
-- by host assembly, which alone resolves blob host paths; it never throws.
type ChatViewBackfill = GroupId -> IO ()

data SandboxRegistry = SandboxRegistry
  { srEntries :: !(TVar (Map SandboxId SandboxEntry)),
    srDbPool :: !DbPool,
    srBackfill :: !ChatViewBackfill,
    -- | Serializes first use per group, so concurrent calls share one sandbox.
    srStarting :: !(LockMap GroupId)
  }

newDurableSandboxRegistry :: DbPool -> ChatViewBackfill -> IO SandboxRegistry
newDurableSandboxRegistry pool backfill = do
  registry <- SandboxRegistry <$> newTVarIO Map.empty <*> pure pool <*> pure backfill <*> newLockMap
  reconcileSandboxes registry
  pure registry

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
reconcileSandboxes reg = do
  let pool = reg.srDbPool
  now <- getCurrentTime
  rows <- loadPersisted pool
  containers <- Set.fromList <$> listContainersByPrefix namePrefix
  volumes <- Set.fromList <$> listVolumesByPrefix namePrefix
  let knownContainers = Set.fromList (map (.psContainer) rows)
      knownVolumes = Set.fromList (map (.psVolume) rows)
  for_ rows $ \row ->
    if row.psExpiresAt <= now
      then void (destroyPersisted reg row)
      else withPersistedAccess reg row $ do
        -- Namespace listings are only an orphan-cleanup optimization.  A
        -- persisted row is destroyed only after a per-resource inspection
        -- positively reports absence; daemon/CLI failure is not absence.
        volumeState <- inspectVolumePresence row.psVolume
        case volumeState of
          RuntimeAbsent -> do
            runRm row.psContainer
            atomically $ modifyTVar' reg.srEntries (Map.delete (SandboxId row.psHandle))
            markSandboxDestroyed pool row.psId "durable volume missing during boot reconciliation"
          RuntimeUnavailable detail ->
            markSandboxUnknown pool row.psId detail
          RuntimePresent -> do
            containerState <- inspectContainerStatus row.psContainer
            case containerState of
              RuntimeContainerRunning -> do
                currentPolicy <- inspectContainerPolicy row.psContainer row.psNetwork
                if currentPolicy && persistedPolicyCurrent row
                  then adoptPersisted reg pool row
                  else rebuildPersisted reg pool row
              RuntimeContainerStopped -> rebuildPersisted reg pool row
              RuntimeContainerMissing -> rebuildPersisted reg pool row
              RuntimeContainerUnavailable detail ->
                markSandboxUnknown pool row.psId detail
  for_ (Set.toList (containers `Set.difference` knownContainers)) runRm
  for_ (Set.toList (volumes `Set.difference` knownVolumes)) runVolumeRm

-- The cached gate survives adoption and coordinates hourly reconciliation
-- with tool calls. On boot no commands can reference uncached entries yet.
withPersistedAccess :: SandboxRegistry -> PersistedSandbox -> IO a -> IO a
withPersistedAccess reg row action = do
  entries <- readTVarIO reg.srEntries
  case Map.lookup (SandboxId row.psHandle) entries of
    Nothing -> action
    Just entry -> withExclusiveLock entry.seAccess action

gcExpiredSandboxes :: SandboxRegistry -> IO Int
gcExpiredSandboxes reg = do
  let pool = reg.srDbPool
  now <- getCurrentTime
  rows <- filter ((<= now) . (.psExpiresAt)) <$> loadPersisted pool
  outcomes <- traverse (destroyPersisted reg) rows
  pure (length (filter id outcomes))

adoptPersisted :: SandboxRegistry -> DbPool -> PersistedSandbox -> IO ()
adoptPersisted reg pool row = do
  entry <- entryFromPersisted row
  -- Hourly reconciliation must not replace the per-sandbox access gate while
  -- commands are using it.  Keep the live cache entry when present; a fresh one
  -- is needed only on boot or after this process has evicted the sandbox.
  atomically (modifyTVar' reg.srEntries (Map.insertWith (\new old -> old {seNetwork = new.seNetwork, seImage = new.seImage}) entry.seId entry))
  markSandboxActive pool row.psId

rebuildPersisted :: SandboxRegistry -> DbPool -> PersistedSandbox -> IO ()
rebuildPersisted reg pool row = do
  selected <- networkForGroup (fromIntegral row.psGroup)
  case selected of
    Left detail -> markSandboxUnknown pool row.psId detail
    Right network -> do
      let secured = (securePersisted row) {psNetwork = network}
      -- A stopped container still owns its name; preserve its durable volume.
      runRm row.psContainer
      updateSandboxRuntime pool secured
      runRun secured.psContainer secured.psImage secured.psVolume secured.psNetwork >>= \case
        Right _ -> adoptPersisted reg pool secured >> reg.srBackfill (GroupId secured.psGroup)
        Left detail -> markSandboxUnknown pool row.psId detail

--------------------------------------------------------------------------------
-- Create options.

data SandboxCreateOpts = SandboxCreateOpts
  { scoImage :: !Text,
    scoNetwork :: !Text
  }
  deriving stock (Show)

-- | The host module owns the prebuilt NixOS closure and pinned package source.
-- Legacy database image/network columns now record this runtime profile.
defaultCreateOpts :: SandboxCreateOpts
defaultCreateOpts =
  SandboxCreateOpts
    { scoImage = "nixos-sandbox-v1",
      scoNetwork = sandboxNetwork
    }

--------------------------------------------------------------------------------
-- Create.

createSandbox ::
  SandboxRegistry ->
  GroupId ->
  SandboxCreateOpts ->
  IO (Either Text SandboxEntry)
createSandbox reg gid opts = do
  selected <- networkForGroup (let GroupId raw = gid in fromIntegral raw)
  case selected of
    Left detail -> pure (Left detail)
    Right network -> createWithNetwork reg gid opts network

createWithNetwork :: SandboxRegistry -> GroupId -> SandboxCreateOpts -> Text -> IO (Either Text SandboxEntry)
createWithNetwork reg gid opts network = do
  now <- getCurrentTime
  -- Image and network are operator policy, never model-selected authority.
  -- Keep the argument for the internal API shape, but normalize it here so a
  -- future caller cannot accidentally re-open the old escape hatch.
  let securedOpts = opts {scoImage = defaultCreateOpts.scoImage, scoNetwork = network}
  allocated <- allocateSandbox reg gid securedOpts now
  let (dbId, sid, container, volume) = allocated
  lock <- newSharedLock
  prepare <- newTMVarIO ()
  let entry =
        SandboxEntry
          { seId = sid,
            seGroup = gid,
            seContainer = container,
            seVolume = volume,
            seImage = securedOpts.scoImage,
            seNetwork = securedOpts.scoNetwork,
            seCreatedAt = now,
            seAccess = lock,
            sePrepareLock = prepare
          }
  launched <- runRun container securedOpts.scoImage volume securedOpts.scoNetwork
  case launched of
    Left err -> do
      markSandboxUnknown reg.srDbPool dbId err
      pure (Left err)
    Right _ -> do
      markSandboxActive reg.srDbPool dbId
      atomically $ modifyTVar' reg.srEntries (Map.insert sid entry)
      reg.srBackfill gid
      pure (Right entry)

-- | The group's sandbox, shared by model tools and @! \<cmd\>@: reuse the
-- lowest-id entry (for stability), otherwise start one with
-- 'defaultCreateOpts'.
-- Parallel first calls wait for one start instead of each creating a sandbox.
ensureSandbox :: SandboxRegistry -> GroupId -> IO (Either Text SandboxEntry)
ensureSandbox reg gid =
  current >>= \case
    Just e -> pure (Right e)
    Nothing ->
      withKeyLock reg.srStarting gid $
        current >>= maybe (createSandbox reg gid defaultCreateOpts) (pure . Right)
  where
    current = listToMaybe . sortOn (.seId) <$> listSandboxesForGroup reg gid

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

-- | Run independent commands concurrently; only policy repair is exclusive.
-- Wrong-group and already-destroyed ids return Left.
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
        else withPreparedEntry reg gid sid $ \e network -> do
          prepared <- runPreparePackages e.seContainer packages timeoutSecs
          case prepared of
            Left detail -> pure (Left detail)
            Right storePaths -> do
              executed <- runExec e.seContainer network (wrapPackages storePaths cmd) timeoutSecs
              -- Invocation failure leaves the write's outcome unknown.
              -- A real nonzero shell exit remains a committed result.
              pure $ if executed.erExitCode == -1 then Left executed.erStderr else Right executed

-- | Resolve and ready one sandbox, then run under shared access.
withPreparedEntry :: SandboxRegistry -> GroupId -> SandboxId -> (SandboxEntry -> Text -> IO (Either Text a)) -> IO (Either Text a)
withPreparedEntry reg gid sid action = do
  mEntry <- listSandbox reg gid sid
  case mEntry of
    Nothing -> pure (Left "sandbox not found")
    Just e ->
      prepareEntry reg gid e >>= \case
        Left detail -> pure (Left detail)
        Right ready -> withSharedLock e.seAccess $ do
          present <- Map.member sid <$> readTVarIO reg.srEntries
          if present then action e ready else pure (Left "sandbox not found")

-- | Readiness shared by every command path: repair an instance created under
-- an outdated policy (backfilling the view the broker re-binds) and return
-- the network commands run on.
prepareEntry :: SandboxRegistry -> GroupId -> SandboxEntry -> IO (Either Text Text)
prepareEntry reg gid e = withLock e.sePrepareLock $ do
  selected <- networkForGroup (let GroupId raw = gid in fromIntegral raw)
  case selected of
    Left detail -> pure (Left detail)
    Right network -> do
      current <- inspectContainerPolicy e.seContainer network
      if current
        then pure (Right network)
        else withExclusiveLock e.seAccess $ do
          present <- Map.member e.seId <$> readTVarIO reg.srEntries
          if not present
            then pure (Left "sandbox not found")
            else do
              launched <- runRun e.seContainer e.seImage e.seVolume network
              case launched of
                Left detail -> pure (Left detail)
                Right _ -> do
                  atomically $ modifyTVar' reg.srEntries (Map.adjust (\entry -> entry {seNetwork = network}) e.seId)
                  withConn reg.srDbPool $ \conn -> void $ execute conn "UPDATE sandboxes SET network_mode = ? WHERE sandbox_handle = ?" (network, e.seId.unSandboxId)
                  reg.srBackfill gid
                  pure (Right network)

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

-- | At most @maxBytes@ of one file, classified as text or binary.
readSandboxFile ::
  SandboxRegistry ->
  GroupId ->
  SandboxId ->
  Text ->
  Int ->
  IO (Either Text SandboxRead)
readSandboxFile reg gid sid path maxBytes =
  withPreparedEntry reg gid sid $ \e _ ->
    fmap (classifyRead maxBytes) <$> runReadPrefix e.seContainer path (maxBytes + 1)

writeSandboxFile ::
  SandboxRegistry ->
  GroupId ->
  SandboxId ->
  Text ->
  Text ->
  IO (Either Text ())
writeSandboxFile reg gid sid path content =
  withPreparedEntry reg gid sid $ \e _ -> runWrite e.seContainer path content

-- | A complete artifact for publication, read once so the published bytes
-- are exactly what was read.
readSandboxBytes :: SandboxRegistry -> GroupId -> SandboxId -> Text -> IO (Either Text BS.ByteString)
readSandboxBytes reg gid sid path =
  withPreparedEntry reg gid sid $ \e _ -> readSandboxArtifact e.seContainer path

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

-- Exclusive lifecycle access drains every active command before destruction.
-- Once destruction begins, the cache entry is removed even if the runtime becomes
-- unavailable; the durable row remains outcome-unknown for reconciliation.
releaseSandbox :: SandboxRegistry -> SandboxEntry -> IO (Either Text ())
releaseSandbox reg entry =
  withExclusiveLock entry.seAccess $
    do
      markSandboxDestroying reg.srDbPool entry.seId
      cleaned <- cleanupSandbox entry
      atomically $ modifyTVar' reg.srEntries (Map.delete entry.seId)
      case cleaned of
        Right () -> do
          markSandboxDestroyedByHandle reg.srDbPool entry.seId "explicit destroy"
          pure (Right ())
        Left detail -> do
          markSandboxUnknownByHandle reg.srDbPool entry.seId detail
          pure (Left "sandbox volume cleanup failed; state retained for reconciliation")

cleanupSandbox :: SandboxEntry -> IO (Either Text ())
cleanupSandbox entry = do
  runRm entry.seContainer
  runVolumeRm entry.seVolume
  inspectVolumePresence entry.seVolume >>= \case
    RuntimeAbsent -> pure (Right ())
    RuntimePresent -> pure (Left "volume cleanup failed; durable volume still exists")
    RuntimeUnavailable detail -> pure (Left ("destruction outcome unknown: " <> detail))

--------------------------------------------------------------------------------
-- Durable metadata helpers.

allocateSandbox ::
  SandboxRegistry ->
  GroupId ->
  SandboxCreateOpts ->
  UTCTime ->
  IO (Int64, SandboxId, Text, Text)
allocateSandbox reg (GroupId rawGroup) opts now = withConn reg.srDbPool $ \conn -> withTransaction conn $ do
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
  lock <- newSharedLock
  prepare <- newTMVarIO ()
  pure
    SandboxEntry
      { seId = SandboxId row.psHandle,
        seGroup = GroupId row.psGroup,
        seContainer = row.psContainer,
        seVolume = row.psVolume,
        seImage = row.psImage,
        seNetwork = row.psNetwork,
        seCreatedAt = row.psCreatedAt,
        seAccess = lock,
        sePrepareLock = prepare
      }

persistedPolicyCurrent :: PersistedSandbox -> Bool
persistedPolicyCurrent row =
  row.psImage == defaultCreateOpts.scoImage
    && row.psNetwork `elem` [sandboxNetwork, "maxops"]

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
touchSandbox reg entry = withConn reg.srDbPool $ \conn -> do
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
          RuntimeAbsent -> markSandboxDestroyed pool row.psId "sandbox TTL expired" >> pure True
          RuntimePresent -> markSandboxUnknown pool row.psId "TTL cleanup failed; durable volume still exists" >> pure False
          RuntimeUnavailable detail -> markSandboxUnknown pool row.psId ("TTL destruction outcome unknown: " <> detail) >> pure False
      withEntryLock action = do
        entries <- readTVarIO reg.srEntries
        case Map.lookup sid entries of
          Nothing -> action
          Just entry ->
            withExclusiveLock
              entry.seAccess
              action
  withEntryLock (cleanup reg.srDbPool)
