module Max.MaintenanceLeaseSpec (spec) where

import Control.Concurrent qualified as IO
import Control.Concurrent.Async (async, wait)
import Database.PostgreSQL.Simple (execute_)
import Effectful.Concurrent qualified as Concurrent
import Helpers (requireJust, truncateAll, withDb, withDbConcurrent)
import Max.DB.Connection (DbPool, withConn)
import Max.MaintenanceLease
import Test.Hspec

spec :: DbPool -> Spec
spec pool = before_ (truncateAll pool) $ describe "Max.MaintenanceLease" $ do
  it "serializes one domain while allowing independent maintenance domains" $ do
    dream <- withDb pool $ claimMaintenanceLease MemoryDreamMaintenance "worker-a" 60
    dream `shouldSatisfy` (/= Nothing)

    withDb pool (claimMaintenanceLease MemoryDreamMaintenance "worker-b" 60)
      `shouldReturn` Nothing

    embedding <- withDb pool $ claimMaintenanceLease EmbeddingMaintenance "worker-b" 60
    embedding `shouldSatisfy` (/= Nothing)
    fmap (.mlFencingToken) embedding `shouldBe` Just 1

  it "uses fencing tokens so an expired owner cannot touch its successor" $ do
    first <-
      withDb pool (claimMaintenanceLease ContextRebuildMaintenance "worker-a" 60)
        >>= requireJust "first lease"
    withConn pool $ \conn -> do
      _ <-
        execute_
          conn
          "UPDATE maintenance_leases \
          \ SET heartbeat_at = now() - interval '2 minutes', \
          \     expires_at = now() - interval '1 minute' \
          \ WHERE domain = 'context_rebuild'"
      pure ()

    second <-
      withDb pool (claimMaintenanceLease ContextRebuildMaintenance "worker-b" 60)
        >>= requireJust "replacement lease"
    second.mlFencingToken `shouldBe` first.mlFencingToken + 1

    withDb pool (renewMaintenanceLease first 60) `shouldReturn` False
    withDb pool (releaseMaintenanceLease first) `shouldReturn` False
    withDb pool (renewMaintenanceLease second 60) `shouldReturn` True
    withDb pool (releaseMaintenanceLease second) `shouldReturn` True

  it "fences a stale owner's projection mutation after takeover" $ do
    first <-
      withDb pool (claimMaintenanceLease EmbeddingMaintenance "worker-a" 60)
        >>= requireJust "first lease"
    withConn pool $ \conn -> do
      _ <-
        execute_
          conn
          "UPDATE maintenance_leases \
          \ SET heartbeat_at = now() - interval '2 seconds', \
          \     expires_at = now() - interval '1 second' \
          \ WHERE domain = 'embedding'"
      pure ()
    second <-
      withDb pool (claimMaintenanceLease EmbeddingMaintenance "worker-b" 60)
        >>= requireJust "replacement lease"

    withDb pool (withMaintenanceFence first (pure ("stale" :: String)))
      `shouldReturn` Nothing
    withDb pool (withMaintenanceFence second (pure ("current" :: String)))
      `shouldReturn` Just "current"

  it "renews a lease while its action is still running" $ do
    running <-
      async $
        withDbConcurrent pool $
          withMaintenanceLease EmbeddingMaintenance "worker-a" 2 $ \_ ->
            Concurrent.threadDelay 2_500_000
    IO.threadDelay 2_100_000
    withDb pool (claimMaintenanceLease EmbeddingMaintenance "worker-b" 2)
      `shouldReturn` Nothing
    wait running `shouldReturn` MaintenanceCompleted ()
