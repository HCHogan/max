module Max.MaintenanceLeaseSpec (spec) where

import Database.PostgreSQL.Simple (execute_)
import Helpers (truncateAll, withDb)
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

requireJust :: String -> Maybe a -> IO a
requireJust label = \case
  Just value -> pure value
  Nothing -> expectationFailure ("missing " <> label) >> error ("missing " <> label)
