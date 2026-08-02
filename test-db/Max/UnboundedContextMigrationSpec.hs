module Max.UnboundedContextMigrationSpec (spec) where

import Data.Int (Int64)
import Data.String (fromString)
import Data.Text (Text)
import Database.PostgreSQL.Simple (Only (..), execute_, query, withTransaction)
import Database.PostgreSQL.Simple.Types (PGArray (..))
import Max.DB.Connection (DbPool, withConn)
import Test.Hspec

-- | Rehearse the irreversible reader cutover over populated pre-047 tables.
-- User-visible Session state and the live Historian cursor must survive while
-- only the two retired anchors and legacy extractor cursor disappear.  The
-- follow-up trace migration must preserve old rows and accept emergency reads.
spec :: DbPool -> Spec
spec pool = describe "047/048 unbounded-context cutover migrations" $ do
  it "preserves live state while removing only legacy context artifacts" $
    withConn pool $ \conn -> withTransaction conn $ do
      _ <- execute_ conn "CREATE SCHEMA unbounded_context_migration_test"
      _ <- execute_ conn "SET LOCAL search_path TO unbounded_context_migration_test, public"
      _ <-
        execute_
          conn
          "CREATE TABLE sessions ( \
          \ group_id bigint PRIMARY KEY, model text NOT NULL, persona text, \
          \ cleared_at timestamptz, pinned bigint[] NOT NULL, revision bigint NOT NULL, \
          \ context_anchor timestamptz, memx_anchor timestamptz)"
      _ <-
        execute_
          conn
          "INSERT INTO sessions VALUES (42, 'candidate', 'kept persona', now(), ARRAY[7,8], 9, now(), now())"
      _ <-
        execute_
          conn
          "CREATE TABLE conversation_cursors ( \
          \ conversation_id bigint NOT NULL, cursor_name text NOT NULL, ingest_seq bigint NOT NULL, \
          \ updated_at timestamptz NOT NULL DEFAULT now(), PRIMARY KEY (conversation_id, cursor_name))"
      _ <-
        execute_
          conn
          "INSERT INTO conversation_cursors VALUES \
          \ (42, 'historian', 123, now()), (42, 'memory_extract', 88, now())"
      _ <-
        execute_
          conn
          "CREATE TABLE context_plan_traces ( \
          \ history_mode text NOT NULL, \
          \ CONSTRAINT context_plan_traces_history_mode_check CHECK (history_mode IN ('legacy','tiered')))"
      _ <- execute_ conn "INSERT INTO context_plan_traces VALUES ('legacy'), ('tiered')"

      cutover <- readFile "migrations/047_unbounded_context_cutover.sql"
      _ <- execute_ conn (fromString cutover)
      emergency <- readFile "migrations/048_context_emergency_reader.sql"
      _ <- execute_ conn (fromString emergency)

      sessionRows <-
        query
          conn
          "SELECT group_id, model, persona, pinned, revision FROM sessions"
          ()
      (sessionRows :: [(Int64, Text, Maybe Text, PGArray Int64, Int64)])
        `shouldBe` [(42, "candidate", Just "kept persona", PGArray [7, 8], 9)]
      cursors <-
        query
          conn
          "SELECT cursor_name, ingest_seq FROM conversation_cursors ORDER BY cursor_name"
          ()
      (cursors :: [(Text, Int64)]) `shouldBe` [("historian", 123)]
      columns <-
        query
          conn
          "SELECT count(*) FROM information_schema.columns \
          \ WHERE table_schema = current_schema() AND table_name = 'sessions' \
          \   AND column_name IN ('context_anchor', 'memx_anchor')"
          ()
      (columns :: [Only Int64]) `shouldBe` [Only 0]
      _ <- execute_ conn "INSERT INTO context_plan_traces VALUES ('raw_emergency')"
      modes <- query conn "SELECT history_mode FROM context_plan_traces ORDER BY history_mode" ()
      (modes :: [Only Text]) `shouldBe` [Only "legacy", Only "raw_emergency", Only "tiered"]

      _ <- execute_ conn "DROP SCHEMA unbounded_context_migration_test CASCADE"
      pure ()
