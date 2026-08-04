module Max.CanonicalPlatformMigrationSpec (spec) where

import Data.Int (Int64)
import Data.String (fromString)
import Data.Text (Text)
import Database.PostgreSQL.Simple (execute_, query, withTransaction)
import Max.DB.Connection (DbPool, withConn)
import Test.Hspec

-- | Rehearse the one-time 049/050 backfill over populated legacy tables. The
-- final runtime never exercises the transitional legacy-writer triggers;
-- migration 061 removes them before the atomic cutover binary starts.
spec :: DbPool -> Spec
spec pool = describe "049/050 canonical platform foundation migrations" $ do
  it "backfills rows already present at the offline cutover boundary" $
    withConn pool $ \conn -> withTransaction conn $ do
      _ <- execute_ conn "CREATE SCHEMA canonical_platform_migration_test"
      _ <- execute_ conn "SET LOCAL search_path TO canonical_platform_migration_test, public"
      _ <- execute_ conn "CREATE SEQUENCE messages_ingest_seq_seq AS bigint"
      _ <- execute_ conn "CREATE SEQUENCE synthetic_message_id_seq AS bigint"
      _ <-
        execute_
          conn
          "CREATE TABLE platform_ids ( \
          \ platform text NOT NULL, kind text NOT NULL, native_id text NOT NULL, \
          \ mapped_id bigint PRIMARY KEY, UNIQUE(platform, kind, native_id))"
      _ <-
        execute_
          conn
          "CREATE TABLE messages ( \
          \ message_id bigint PRIMARY KEY, group_id bigint NOT NULL, user_id bigint NOT NULL, \
          \ self_id bigint NOT NULL, received_at timestamptz NOT NULL DEFAULT now(), \
          \ segments jsonb NOT NULL, rendered_text text NOT NULL, raw_message text NOT NULL DEFAULT '', \
          \ sender_nickname text, sender_card text, reply_to_message_id bigint, \
          \ ingest_seq bigint NOT NULL DEFAULT nextval('messages_ingest_seq_seq'), \
          \ kind text NOT NULL DEFAULT 'chat', UNIQUE(ingest_seq))"
      _ <-
        execute_
          conn
          "INSERT INTO messages \
          \ (message_id, group_id, user_id, self_id, segments, rendered_text, sender_nickname) \
          \ VALUES (101, 42, 7, 9, '[]', 'before migration', 'alice')"

      migration <- readFile "migrations/049_canonical_platform_foundation.sql"
      _ <- execute_ conn (fromString migration)
      runtimeMigration <- readFile "migrations/050_platform_runtime_hardening.sql"
      _ <- execute_ conn (fromString runtimeMigration)

      backfilled <-
        query
          conn
          "SELECT m.canonical_message_id, c.legacy_group_id, a.platform, m.source_platform, m.message_origin, \
          \       e.native_conversation_id, pi.native_user_id, pe.native_event_id, d.status \
          \FROM messages m \
          \JOIN conversations c USING (conversation_id) \
          \JOIN conversation_endpoints e ON e.endpoint_id = m.origin_endpoint_id \
          \JOIN platform_accounts a USING (platform_account_id) \
          \JOIN principal_identities pi ON pi.principal_id = m.author_principal_id \
          \JOIN platform_events pe USING (canonical_message_id) \
          \JOIN message_deliveries d USING (canonical_message_id)"
          ()
      (backfilled :: [(Int64, Int64, Text, Text, Text, Text, Text, Text, Text)])
        `shouldBe` [(1, 42, "qq", "qq", "legacy", "42", "7", "101", "confirmed")]

      _ <- execute_ conn "DROP SCHEMA canonical_platform_migration_test CASCADE"
      pure ()
