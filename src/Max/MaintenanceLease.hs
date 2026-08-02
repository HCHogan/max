-- |
-- Durable named leases for background projection maintenance.
--
-- The fencing token is part of the handle and every renew/release predicate.
-- A worker whose lease expired cannot release or extend the newer owner's
-- lease.  Store-level CAS remains the final fence around each projection
-- mutation; this layer prevents duplicate expensive work across processes.
module Max.MaintenanceLease
  ( MaintenanceDomain (..),
    MaintenanceLease (..),
    maintenanceDomainText,
    claimMaintenanceLease,
    renewMaintenanceLease,
    releaseMaintenanceLease,
    withMaintenanceLease,
  )
where

import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as T
import Database.PostgreSQL.Simple (Only (..))
import Effectful
import Effectful.Exception (finally)
import Effectful.PostgreSQL (WithConnection, execute, query)

data MaintenanceDomain
  = MemoryDreamMaintenance
  | EmbeddingMaintenance
  | ContextRebuildMaintenance
  deriving stock (Show, Eq, Ord)

data MaintenanceLease = MaintenanceLease
  { mlDomain :: !MaintenanceDomain,
    mlOwner :: !Text,
    mlFencingToken :: !Int64
  }
  deriving stock (Show, Eq)

maintenanceDomainText :: MaintenanceDomain -> Text
maintenanceDomainText = \case
  MemoryDreamMaintenance -> "memory_dream"
  EmbeddingMaintenance -> "embedding"
  ContextRebuildMaintenance -> "context_rebuild"

claimMaintenanceLease ::
  (WithConnection :> es, IOE :> es) =>
  MaintenanceDomain ->
  Text ->
  Int ->
  Eff es (Maybe MaintenanceLease)
claimMaintenanceLease domain owner ttlSeconds
  | T.null (T.strip owner) = pure Nothing
  | ttlSeconds <= 0 = pure Nothing
  | otherwise = do
      rows <-
        query
          "INSERT INTO maintenance_leases \
          \  (domain, owner, fencing_token, acquired_at, heartbeat_at, expires_at) \
          \ VALUES (?, ?, 1, now(), now(), now() + (? * interval '1 second')) \
          \ ON CONFLICT (domain) DO UPDATE \
          \ SET owner = EXCLUDED.owner, \
          \     fencing_token = maintenance_leases.fencing_token + 1, \
          \     acquired_at = now(), heartbeat_at = now(), \
          \     expires_at = EXCLUDED.expires_at \
          \ WHERE maintenance_leases.expires_at <= now() \
          \ RETURNING fencing_token"
          (maintenanceDomainText domain, T.strip owner, ttlSeconds)
      pure $ case rows of
        [Only token] -> Just (MaintenanceLease domain (T.strip owner) token)
        _ -> Nothing

renewMaintenanceLease ::
  (WithConnection :> es, IOE :> es) =>
  MaintenanceLease ->
  Int ->
  Eff es Bool
renewMaintenanceLease lease ttlSeconds
  | ttlSeconds <= 0 = pure False
  | otherwise = do
      changed <-
        execute
          "UPDATE maintenance_leases \
          \ SET heartbeat_at = now(), expires_at = now() + (? * interval '1 second') \
          \ WHERE domain = ? AND owner = ? AND fencing_token = ? \
          \   AND expires_at > now()"
          ( ttlSeconds,
            maintenanceDomainText lease.mlDomain,
            lease.mlOwner,
            lease.mlFencingToken
          )
      pure (changed == 1)

releaseMaintenanceLease ::
  (WithConnection :> es, IOE :> es) =>
  MaintenanceLease ->
  Eff es Bool
releaseMaintenanceLease lease = do
  changed <-
    execute
      "DELETE FROM maintenance_leases \
      \ WHERE domain = ? AND owner = ? AND fencing_token = ?"
      (maintenanceDomainText lease.mlDomain, lease.mlOwner, lease.mlFencingToken)
  pure (changed == 1)

-- | Run an action only while this process owns the named lease.  Release is
-- best-effort and fenced; cancellation cannot delete a successor's lease.
withMaintenanceLease ::
  (WithConnection :> es, IOE :> es) =>
  MaintenanceDomain ->
  Text ->
  Int ->
  (MaintenanceLease -> Eff es a) ->
  Eff es (Maybe a)
withMaintenanceLease domain owner ttlSeconds action =
  claimMaintenanceLease domain owner ttlSeconds >>= \case
    Nothing -> pure Nothing
    Just lease ->
      Just <$> action lease `finally` (releaseMaintenanceLease lease >> pure ())
