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
-- An unset 'MAX_TEST_DB_URL' is a failed integration gate, not a passing empty
-- suite.  CI and release checks must provide a real PostgreSQL database.
module Main (main) where

import Control.Exception (bracket)
import Data.Text qualified as T
import Helpers (truncateAll)
import Max.AdminTimelineSpec qualified as AdminTimelineSpec
import Max.ContextAdminSpec qualified as ContextAdminSpec
import Max.ContextMaterializationSpec qualified as ContextMaterializationSpec
import Max.DB.AgentTurnSpec qualified as AgentTurnSpec
import Max.DB.Connection (DbConfig (..), closeDbPool, newDbPool)
import Max.DB.ConnectionSpec qualified as ConnectionSpec
import Max.DB.ConversationCursorSpec qualified as ConversationCursorSpec
import Max.DB.FetchQueueSpec qualified as FetchQueueSpec
import Max.DB.FilesSpec qualified as FilesSpec
import Max.DB.HistorySpec qualified as HistorySpec
import Max.DB.MediaSpec qualified as MediaSpec
import Max.DB.Migrations (runMigrations)
import Max.DB.MonitorSpec qualified as MonitorSpec
import Max.DB.TaskSpec qualified as TaskSpec
import Max.DB.BrowserSpec qualified as BrowserSpec
import Max.DB.QQBackfillSpec qualified as QQBackfillSpec
import Max.DB.SessionSpec qualified as SessionSpec
import Max.DB.TransactionSpec qualified as TransactionSpec
import Max.EpisodeStoreSpec qualified as EpisodeStoreSpec
import Max.HistorianSpec qualified as HistorianSpec
import Max.MaintenanceLeaseSpec qualified as MaintenanceLeaseSpec
import Max.MemoryStoreSpec qualified as MemoryStoreSpec
import Max.PlatformStoreSpec qualified as PlatformStoreSpec
import Max.PromptIntegrationSpec qualified as PromptIntegrationSpec
import Max.RecallSpec qualified as RecallSpec
import System.Environment (lookupEnv)
import System.Exit (die)
import Test.Hspec (hspec)

main :: IO ()
main = do
  mUrl <- lookupEnv "MAX_TEST_DB_URL"
  case mUrl of
    Nothing -> do
      die
        "MAX_TEST_DB_URL not set; refusing to report a skipped DB integration suite as passing.\n\
        \  e.g. export MAX_TEST_DB_URL=postgresql://127.0.0.1:5433/max_test"
    Just url -> bracket (newDbPool (DbConfig (T.pack url) 4)) closeDbPool $ \pool -> do
      applied <- runMigrations pool "migrations"
      case applied of
        [] -> putStrLn "migrations: nothing to apply (test DB already up to date)"
        xs -> putStrLn $ "migrations: applied " <> show (length xs) <> " — " <> show xs
      hspec $ do
        AdminTimelineSpec.spec pool
        MaintenanceLeaseSpec.spec pool
        SessionSpec.spec pool
        TransactionSpec.spec pool
        AgentTurnSpec.spec pool
        TaskSpec.spec pool
        BrowserSpec.spec pool
        ConnectionSpec.spec pool
        ConversationCursorSpec.spec pool
        ContextMaterializationSpec.spec pool
        ContextAdminSpec.spec pool
        EpisodeStoreSpec.spec pool
        HistorianSpec.spec pool
        HistorySpec.spec pool
        FilesSpec.spec pool
        MemoryStoreSpec.spec pool
        MediaSpec.spec pool
        FetchQueueSpec.spec pool
        MonitorSpec.spec pool
        QQBackfillSpec.spec pool
        RecallSpec.spec pool
        PromptIntegrationSpec.spec pool
        PlatformStoreSpec.spec pool
      -- Final wipe so a developer running tests against the dev DB
      -- doesn't leave random fixture rows behind.
      truncateAll pool
