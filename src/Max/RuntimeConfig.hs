-- |
-- Immutable, generation-tagged configuration used by one dispatch.
--
-- A reload publishes a whole 'RuntimeValues' at once.  Dispatches acquire a
-- lease on the current snapshot and retain it until their outer finalizer, so
-- a running turn cannot observe half of one configuration and half of the
-- next.  Superseded snapshots are removed as soon as their final lease is
-- released; in particular, old endpoint credentials are not retained forever.
module Max.RuntimeConfig
  ( ConfigGeneration (..),
    RuntimeValues (..),
    RuntimeResources (..),
    RuntimeSnapshot (..),
    RuntimeConfigStore,
    RuntimeConfigLease,
    newRuntimeConfigStore,
    currentRuntimeSnapshot,
    acquireRuntimeConfigSTM,
    releaseRuntimeConfigSTM,
    publishRuntimeConfigSTM,
    lookupRuntimeSnapshot,
    leasedRuntimeSnapshot,
    retainedRuntimeGenerations,
  )
where

import Control.Concurrent.STM
  ( STM,
    TVar,
    newTVarIO,
    readTVar,
    readTVarIO,
    writeTVar,
  )
import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Time (TimeZone)
import Data.Word (Word64)
import Log (LogLevel)
import Max.CliProxy (CliProxyConfig)
import Max.Embedding (EmbedClient)
import Max.Intent.Types (IntentConfig)
import Max.MaxOps.Types (MaxOpsConfig)
import Max.ModelCatalog (ModelCatalog)
import Max.Platform (PlatformBackend)
import Max.Platform.Delivery (DeliveryTransport)
import Max.Tools.Search.Types (SearchConfig)

newtype ConfigGeneration = ConfigGeneration {unConfigGeneration :: Word64}
  deriving stock (Show, Eq, Ord)

-- | The configuration a dispatch is allowed to observe.  Process-lifetime
-- handles (DB pool, task/session registries, OneBot client slot, browser and
-- sandbox ownership) deliberately live elsewhere.
data RuntimeValues = RuntimeValues
  { rvPersona :: !Text,
    rvForceRawContext :: !Bool,
    rvDebugDefault :: !Bool,
    rvStickerDefault :: !Bool,
    rvDefaultModel :: !Text,
    rvTimeZone :: !TimeZone,
    rvTurnSilenceSeconds :: !Int,
    rvOwners :: ![Int64],
    rvSearch :: !(Maybe SearchConfig),
    rvMaxOps :: !MaxOpsConfig,
    rvCliProxy :: !(Maybe CliProxyConfig),
    rvBrowserProxy :: !(Maybe Text),
    rvMemoryExtract :: !(Maybe Text),
    rvIntent :: !(Maybe IntentConfig),
    rvEmbeddingEnabled :: !Bool,
    rvModelCatalog :: !ModelCatalog,
    rvLogLevel :: !LogLevel
  }
  deriving stock (Eq)

-- | Prepared handles owned by exactly the same generation as 'RuntimeValues'.
-- They are built before publication and retained by old dispatch leases, so a
-- turn cannot jump to a replacement endpoint midway through its tool loop.
data RuntimeResources = RuntimeResources
  { rrEmbeddingClient :: !(Maybe EmbedClient),
    rrForeignEdges :: ![PlatformBackend],
    rrDeliveryTransports :: ![DeliveryTransport]
  }

data RuntimeSnapshot = RuntimeSnapshot
  { rsGeneration :: !ConfigGeneration,
    rsValues :: !RuntimeValues,
    rsResources :: !RuntimeResources
  }

data RuntimeEntry = RuntimeEntry
  { reSnapshot :: !RuntimeSnapshot,
    reLeases :: !Int
  }

data RuntimeState = RuntimeState
  { rstCurrent :: !ConfigGeneration,
    rstEntries :: !(Map ConfigGeneration RuntimeEntry)
  }

newtype RuntimeConfigStore = RuntimeConfigStore (TVar RuntimeState)

data RuntimeConfigLease = RuntimeConfigLease
  { rclStore :: !RuntimeConfigStore,
    rclSnapshot :: !RuntimeSnapshot
  }

newRuntimeConfigStore :: RuntimeValues -> RuntimeResources -> IO RuntimeConfigStore
newRuntimeConfigStore values resources = do
  let generation = ConfigGeneration 1
      snapshot = RuntimeSnapshot generation values resources
      entry = RuntimeEntry snapshot 0
  RuntimeConfigStore <$> newTVarIO (RuntimeState generation (Map.singleton generation entry))

currentRuntimeSnapshot :: RuntimeConfigStore -> IO RuntimeSnapshot
currentRuntimeSnapshot (RuntimeConfigStore stateVar) = do
  state <- readTVarIO stateVar
  pure (currentEntry state).reSnapshot

acquireRuntimeConfigSTM :: RuntimeConfigStore -> STM RuntimeConfigLease
acquireRuntimeConfigSTM store@(RuntimeConfigStore stateVar) = do
  state <- readTVar stateVar
  let generation = state.rstCurrent
      entry = currentEntry state
      state' =
        state
          { rstEntries =
              Map.insert generation (entry {reLeases = entry.reLeases + 1}) state.rstEntries
          }
  writeTVar stateVar state'
  pure (RuntimeConfigLease store entry.reSnapshot)

releaseRuntimeConfigSTM :: RuntimeConfigLease -> STM ()
releaseRuntimeConfigSTM lease = do
  let RuntimeConfigStore stateVar = lease.rclStore
      generation = lease.rclSnapshot.rsGeneration
  state <- readTVar stateVar
  case Map.lookup generation state.rstEntries of
    Nothing -> pure ()
    Just entry -> do
      let leases' = max 0 (entry.reLeases - 1)
          entries'
            | generation /= state.rstCurrent && leases' == 0 = Map.delete generation state.rstEntries
            | otherwise = Map.insert generation (entry {reLeases = leases'}) state.rstEntries
      writeTVar stateVar state {rstEntries = entries'}

publishRuntimeConfigSTM :: RuntimeConfigStore -> RuntimeValues -> RuntimeResources -> STM (RuntimeSnapshot, RuntimeSnapshot)
publishRuntimeConfigSTM (RuntimeConfigStore stateVar) values resources = do
  state <- readTVar stateVar
  let oldEntry = currentEntry state
      ConfigGeneration current = state.rstCurrent
      nextGeneration = ConfigGeneration (current + 1)
      nextSnapshot = RuntimeSnapshot nextGeneration values resources
      oldEntries
        | oldEntry.reLeases == 0 = Map.delete state.rstCurrent state.rstEntries
        | otherwise = state.rstEntries
      entries' = Map.insert nextGeneration (RuntimeEntry nextSnapshot 0) oldEntries
  writeTVar stateVar (RuntimeState nextGeneration entries')
  pure (oldEntry.reSnapshot, nextSnapshot)

lookupRuntimeSnapshot :: RuntimeConfigStore -> ConfigGeneration -> IO (Maybe RuntimeSnapshot)
lookupRuntimeSnapshot (RuntimeConfigStore stateVar) generation = do
  state <- readTVarIO stateVar
  pure (reSnapshot <$> Map.lookup generation state.rstEntries)

leasedRuntimeSnapshot :: RuntimeConfigLease -> RuntimeSnapshot
leasedRuntimeSnapshot = (.rclSnapshot)

retainedRuntimeGenerations :: RuntimeConfigStore -> IO [ConfigGeneration]
retainedRuntimeGenerations (RuntimeConfigStore stateVar) = Map.keys . (.rstEntries) <$> readTVarIO stateVar

currentEntry :: RuntimeState -> RuntimeEntry
currentEntry state = case Map.lookup state.rstCurrent state.rstEntries of
  Just entry -> entry
  Nothing -> error "runtime configuration store lost its current generation"
