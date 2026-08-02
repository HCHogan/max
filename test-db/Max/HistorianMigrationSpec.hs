module Max.HistorianMigrationSpec (spec) where

import Data.Int (Int64)
import Data.String (fromString)
import Data.Text (Text)
import Database.PostgreSQL.Simple (execute_, query, withTransaction)
import Max.DB.Connection (DbPool, withConn)
import Test.Hspec

-- | Exercise the activation migration against existing production-like
-- sessions.  The deployment boundary must prevent an uncontrolled legacy
-- backfill while preserving a cursor already installed by an operator.
spec :: DbPool -> Spec
spec pool = describe "041_historian_worker migration" $ do
  it "baselines existing conversations without overwriting explicit progress" $
    withConn pool $ \conn -> withTransaction conn $ do
      _ <- execute_ conn "CREATE SCHEMA historian_migration_test"
      _ <- execute_ conn "SET LOCAL search_path TO historian_migration_test, public"
      _ <- execute_ conn "CREATE TABLE sessions (group_id bigint PRIMARY KEY)"
      _ <- execute_ conn "CREATE TABLE messages (group_id bigint NOT NULL, ingest_seq bigint NOT NULL)"
      _ <-
        execute_
          conn
          "CREATE TABLE conversation_cursors ( \
          \ conversation_id bigint NOT NULL, cursor_name text NOT NULL, ingest_seq bigint NOT NULL, \
          \ updated_at timestamptz NOT NULL DEFAULT now(), PRIMARY KEY (conversation_id, cursor_name))"
      _ <-
        execute_
          conn
          "CREATE TABLE episode_capture_runs ( \
          \ status text NOT NULL CHECK (status IN ('pending','leased','generated','published','failed')))"
      _ <- execute_ conn "INSERT INTO sessions VALUES (100), (200)"
      _ <- execute_ conn "INSERT INTO messages VALUES (100, 7), (100, 9), (200, 11)"
      _ <- execute_ conn "INSERT INTO conversation_cursors VALUES (200, 'historian', 3)"

      migration <- readFile "migrations/041_historian_worker.sql"
      _ <- execute_ conn (fromString migration)

      cursors <-
        query
          conn
          "SELECT conversation_id, cursor_name, ingest_seq FROM conversation_cursors ORDER BY conversation_id"
          ()
      (cursors :: [(Int64, Text, Int64)])
        `shouldBe` [(100, "historian", 9), (200, "historian", 3)]
      _ <- execute_ conn "INSERT INTO episode_capture_runs VALUES ('abandoned')"

      _ <- execute_ conn "DROP SCHEMA historian_migration_test CASCADE"
      pure ()
