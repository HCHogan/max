module Max.ContextMaterializationMigrationSpec (spec) where

import Data.String (fromString)
import Data.Text (Text)
import Data.Text qualified as T
import Database.PostgreSQL.Simple (Only (..), execute_, query, withTransaction)
import Max.DB.Connection (DbPool, withConn)
import Test.Hspec

-- | Run 043 over the state produced by the earlier development rollout.
-- The mutable current row may be renamed, but the revision ledger is an
-- append-only audit record and must remain byte-for-byte historical.
spec :: DbPool -> Spec
spec pool = describe "043_episode_expand_handle migration" $ do
  it "backfills opaque handles without rewriting append-only revisions" $
    withConn pool $ \conn -> withTransaction conn $ do
      _ <- execute_ conn "CREATE SCHEMA context_materialization_migration_test"
      _ <- execute_ conn "SET LOCAL search_path TO context_materialization_migration_test, public"
      _ <- execute_ conn "CREATE TABLE conversation_compartments (id bigint PRIMARY KEY)"
      _ <- execute_ conn "INSERT INTO conversation_compartments VALUES (1)"
      _ <-
        execute_
          conn
          "CREATE TABLE context_materializations ( \
          \ reason text NOT NULL, \
          \ CONSTRAINT context_materializations_reason_check CHECK ( \
          \   reason IN ('initial_canary', 'high_water', 'projection_change', 'manual_rebuild') \
          \ ))"
      _ <- execute_ conn "INSERT INTO context_materializations VALUES ('initial_canary')"
      _ <- execute_ conn "CREATE TABLE context_materialization_versions (reason text NOT NULL)"
      _ <- execute_ conn "INSERT INTO context_materialization_versions VALUES ('initial_canary')"
      _ <-
        execute_
          conn
          "CREATE FUNCTION reject_context_materialization_version_mutation() \
          \ RETURNS trigger LANGUAGE plpgsql AS $$ \
          \ BEGIN RAISE EXCEPTION 'append-only'; END; $$"
      _ <-
        execute_
          conn
          "CREATE TRIGGER context_materialization_versions_append_only \
          \ BEFORE UPDATE OR DELETE ON context_materialization_versions \
          \ FOR EACH ROW EXECUTE FUNCTION reject_context_materialization_version_mutation()"

      migration <- readFile "migrations/043_episode_expand_handle.sql"
      _ <- execute_ conn (fromString migration)

      currentReasons <- query conn "SELECT reason FROM context_materializations" ()
      historicalReasons <- query conn "SELECT reason FROM context_materialization_versions" ()
      handles <- query conn "SELECT expand_handle::text FROM conversation_compartments" ()
      (currentReasons :: [Only Text]) `shouldBe` [Only "initial_materialization"]
      (historicalReasons :: [Only Text]) `shouldBe` [Only "initial_canary"]
      (handles :: [Only Text]) `shouldSatisfy` \case
        [Only handle] -> T.length handle == 36
        _ -> False

      _ <- execute_ conn "INSERT INTO context_materializations VALUES ('initial_materialization')"
      _ <- execute_ conn "DROP SCHEMA context_materialization_migration_test CASCADE"
      pure ()
