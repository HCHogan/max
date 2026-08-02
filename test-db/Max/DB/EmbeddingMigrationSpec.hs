module Max.DB.EmbeddingMigrationSpec (spec) where

import Data.String (fromString)
import Database.PostgreSQL.Simple (execute_, query, withTransaction)
import Helpers ()
import Max.DB.Connection (DbPool, withConn)
import Test.Hspec

-- | Exercise migration 038 against the shape production had immediately
-- before it: untyped vector columns containing vectors with no provenance.
-- This is isolated in a disposable schema and runs the real migration file.
spec :: DbPool -> Spec
spec pool = describe "038_embedding_provenance migration" $ do
  it "invalidates legacy vectors and installs source-change invalidation" $
    withConn pool $ \conn -> withTransaction conn $ do
      _ <- execute_ conn "CREATE SCHEMA embedding_migration_test"
      _ <- execute_ conn "SET LOCAL search_path TO embedding_migration_test, public"
      _ <- execute_ conn "CREATE TABLE messages (rendered_text text NOT NULL, embedding vector)"
      _ <- execute_ conn "CREATE TABLE memories (content text NOT NULL, embedding vector)"
      _ <- execute_ conn "CREATE TABLE stickers (description text, embedding vector)"
      _ <- execute_ conn "INSERT INTO messages VALUES ('old message', '[1,2,3]')"
      _ <- execute_ conn "INSERT INTO memories VALUES ('old memory', '[1,2,3]')"
      _ <- execute_ conn "INSERT INTO stickers VALUES ('old sticker', '[1,2,3]')"

      migration <- readFile "migrations/038_embedding_provenance.sql"
      _ <- execute_ conn (fromString migration)

      legacyCleared <-
        query
          conn
          "SELECT \
          \ (SELECT embedding IS NULL AND embedding_model IS NULL FROM messages), \
          \ (SELECT embedding IS NULL AND embedding_model IS NULL FROM memories), \
          \ (SELECT embedding IS NULL AND embedding_model IS NULL FROM stickers)"
          ()
      (legacyCleared :: [(Bool, Bool, Bool)]) `shouldBe` [(True, True, True)]

      let install table =
            execute_
              conn
              ( fromString $
                  "UPDATE "
                    <> table
                    <> " SET embedding = '[1,2,3]', embedding_model = 'model-v1', "
                    <> "embedding_dimensions = 3, embedding_content_hash = repeat('a', 64), "
                    <> "embedding_updated_at = now()"
              )
      _ <- install "messages"
      _ <- install "memories"
      _ <- install "stickers"
      _ <- execute_ conn "UPDATE messages SET rendered_text = 'new message'"
      _ <- execute_ conn "UPDATE memories SET content = 'new memory'"
      _ <- execute_ conn "UPDATE stickers SET description = 'new sticker'"

      invalidated <-
        query
          conn
          "SELECT \
          \ (SELECT embedding IS NULL AND embedding_content_hash IS NULL FROM messages), \
          \ (SELECT embedding IS NULL AND embedding_content_hash IS NULL FROM memories), \
          \ (SELECT embedding IS NULL AND embedding_content_hash IS NULL FROM stickers)"
          ()
      (invalidated :: [(Bool, Bool, Bool)]) `shouldBe` [(True, True, True)]

      _ <- execute_ conn "DROP SCHEMA embedding_migration_test CASCADE"
      pure ()
