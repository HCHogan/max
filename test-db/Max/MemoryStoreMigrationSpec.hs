module Max.MemoryStoreMigrationSpec (spec) where

import Data.String (fromString)
import Data.Text (Text)
import Database.PostgreSQL.Simple (Only (..), execute_, query, withTransaction)
import Max.DB.Connection (DbPool, withConn)
import Test.Hspec

-- | Run the real migration over the pre-039 production table shape with
-- legacy rows already present.  Exact citations must remain explicitly
-- unknown; only a group row's logically certain origin may be repaired.
spec :: DbPool -> Spec
spec pool = describe "039_memory_store migration" $ do
  it "backfills stable versions, legacy evidence, audit, and known origins" $
    withConn pool $ \conn -> withTransaction conn $ do
      _ <- execute_ conn "CREATE SCHEMA memory_store_migration_test"
      _ <- execute_ conn "SET LOCAL search_path TO memory_store_migration_test, public"
      _ <-
        execute_
          conn
          "CREATE TABLE memories ( \
          \ id bigserial PRIMARY KEY, \
          \ scope text NOT NULL CHECK (scope IN ('group', 'user')), \
          \ scope_id bigint NOT NULL, content text NOT NULL, source_group_id bigint, \
          \ created_at timestamptz NOT NULL DEFAULT now(), \
          \ updated_at timestamptz NOT NULL DEFAULT now() \
          \)"
      _ <- execute_ conn "INSERT INTO memories (scope, scope_id, content) VALUES ('group', 100, 'group legacy')"
      _ <- execute_ conn "INSERT INTO memories (scope, scope_id, content, source_group_id) VALUES ('user', 3001, 'known user legacy', 100)"
      _ <- execute_ conn "INSERT INTO memories (scope, scope_id, content) VALUES ('user', 3002, 'unknown user legacy')"

      migration <- readFile "migrations/039_memory_store.sql"
      _ <- execute_ conn (fromString migration)

      origins <- query conn "SELECT scope, scope_id, source_group_id FROM memories ORDER BY id" ()
      (origins :: [(Text, Int, Maybe Int)])
        `shouldBe` [("group", 100, Just 100), ("user", 3001, Just 100), ("user", 3002, Nothing)]

      versions <- query conn "SELECT count(*)::int FROM memory_versions" ()
      evidence <-
        query
          conn
          "SELECT evidence_kind, source_conversation_id FROM memory_evidence ORDER BY memory_id"
          ()
      audit <- query conn "SELECT operation, actor_kind FROM memory_mutations ORDER BY memory_id" ()
      (versions :: [Only Int]) `shouldBe` [Only 3]
      (evidence :: [(Text, Maybe Int)])
        `shouldBe` [("legacy", Just 100), ("legacy", Just 100), ("legacy", Nothing)]
      (audit :: [(Text, Text)])
        `shouldBe` replicate 3 ("backfill", "migration")

      _ <- execute_ conn "DROP SCHEMA memory_store_migration_test CASCADE"
      pure ()
