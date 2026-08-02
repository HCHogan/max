-- |
-- Entry point for the DB-integration test suite.
--
-- This suite needs a real Postgres database — see docs/development.md
-- or:
--
-- @
-- export MAX_TEST_DB_URL=postgresql://127.0.0.1:5433/max_test
-- createdb -h 127.0.0.1 -p 5433 max_test
-- cabal test max-test-db
-- @
--
-- When 'MAX_TEST_DB_URL' is unset, the suite exits 0 with a friendly
-- note so CI without a database doesn't break.
module Main (main) where

import Control.Exception (bracket)
import Data.Text qualified as T
import Helpers (truncateAll)
import Max.ContextAdminSpec qualified as ContextAdminSpec
import Max.ContextMaterializationMigrationSpec qualified as ContextMaterializationMigrationSpec
import Max.ContextMaterializationSpec qualified as ContextMaterializationSpec
import Max.DB.Connection (DbConfig (..), closeDbPool, newDbPool)
import Max.DB.ConversationCursorSpec qualified as ConversationCursorSpec
import Max.DB.EmbeddingMigrationSpec qualified as EmbeddingMigrationSpec
import Max.DB.FetchQueueSpec qualified as FetchQueueSpec
import Max.DB.FilesSpec qualified as FilesSpec
import Max.DB.HistorySpec qualified as HistorySpec
import Max.DB.MediaSpec qualified as MediaSpec
import Max.DB.MessageSpec qualified as MessageSpec
import Max.DB.Migrations (runMigrations)
import Max.DB.ReminderSpec qualified as ReminderSpec
import Max.DB.SessionSpec qualified as SessionSpec
import Max.EpisodeStoreSpec qualified as EpisodeStoreSpec
import Max.HistorianMigrationSpec qualified as HistorianMigrationSpec
import Max.HistorianSpec qualified as HistorianSpec
import Max.MaintenanceLeaseSpec qualified as MaintenanceLeaseSpec
import Max.MemoryStoreMigrationSpec qualified as MemoryStoreMigrationSpec
import Max.MemoryStoreSpec qualified as MemoryStoreSpec
import Max.PromptIntegrationSpec qualified as PromptIntegrationSpec
import Max.RecallSpec qualified as RecallSpec
import Max.UnboundedContextMigrationSpec qualified as UnboundedContextMigrationSpec
import System.Environment (lookupEnv)
import System.Exit (exitSuccess)
import Test.Hspec (hspec)

main :: IO ()
main = do
  mUrl <- lookupEnv "MAX_TEST_DB_URL"
  case mUrl of
    Nothing -> do
      putStrLn "MAX_TEST_DB_URL not set — skipping DB integration tests."
      putStrLn "  e.g. export MAX_TEST_DB_URL=postgresql://127.0.0.1:5433/max_test"
      exitSuccess
    Just url -> bracket (newDbPool (DbConfig (T.pack url) 4)) closeDbPool $ \pool -> do
      applied <- runMigrations pool "migrations"
      case applied of
        [] -> putStrLn "migrations: nothing to apply (test DB already up to date)"
        xs -> putStrLn $ "migrations: applied " <> show (length xs) <> " — " <> show xs
      hspec $ do
        EmbeddingMigrationSpec.spec pool
        MemoryStoreMigrationSpec.spec pool
        MaintenanceLeaseSpec.spec pool
        SessionSpec.spec pool
        ConversationCursorSpec.spec pool
        ContextMaterializationMigrationSpec.spec pool
        UnboundedContextMigrationSpec.spec pool
        ContextMaterializationSpec.spec pool
        ContextAdminSpec.spec pool
        EpisodeStoreSpec.spec pool
        HistorianMigrationSpec.spec pool
        HistorianSpec.spec pool
        HistorySpec.spec pool
        FilesSpec.spec pool
        MessageSpec.spec pool
        MemoryStoreSpec.spec pool
        MediaSpec.spec pool
        FetchQueueSpec.spec pool
        ReminderSpec.spec pool
        RecallSpec.spec pool
        PromptIntegrationSpec.spec pool
      -- Final wipe so a developer running tests against the dev DB
      -- doesn't leave random fixture rows behind.
      truncateAll pool
