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
import Max.ConversationCapabilitiesSpec qualified as ConversationCapabilitiesSpec
import Max.DB.AgentTurnSpec qualified as AgentTurnSpec
import Max.DB.BrowserSpec qualified as BrowserSpec
import Max.DB.Connection (DbConfig (..), closeDbPool, newDbPool)
import Max.DB.ConnectionSpec qualified as ConnectionSpec
import Max.DB.ConversationCursorSpec qualified as ConversationCursorSpec
import Max.DB.FilesSpec qualified as FilesSpec
import Max.DB.HistorySpec qualified as HistorySpec
import Max.DB.HttpMonitorSpec qualified as HttpMonitorSpec
import Max.DB.JobSpec qualified as JobSpec
import Max.DB.MediaMissingSpec qualified as MediaMissingSpec
import Max.DB.MediaSpec qualified as MediaSpec
import Max.DB.Migrations (runMigrations)
import Max.DB.MonitorJobsSpec qualified as MonitorJobsSpec
import Max.DB.MonitorSpec qualified as MonitorSpec
import Max.DB.ProgressSpec qualified as ProgressSpec
import Max.DB.ProjectionSpec qualified as ProjectionSpec
import Max.DB.QQBackfillSpec qualified as QQBackfillSpec
import Max.DB.SessionSpec qualified as SessionSpec
import Max.DB.TransactionSpec qualified as TransactionSpec
import Max.EpisodeStoreSpec qualified as EpisodeStoreSpec
import Max.ChatViewSpec qualified as ChatViewSpec
import Max.ExecutionSpec qualified as ExecutionSpec
import Max.HistorianSpec qualified as HistorianSpec
import Max.MemoryCapabilitiesSpec qualified as MemoryCapabilitiesSpec
import Max.MemoryExpirySpec qualified as MemoryExpirySpec
import Max.MemoryStoreSpec qualified as MemoryStoreSpec
import Max.PlatformCapabilitiesSpec qualified as PlatformCapabilitiesSpec
import Max.PlatformStoreSpec qualified as PlatformStoreSpec
import Max.PromptIntegrationSpec qualified as PromptIntegrationSpec
import Max.PublicationSpec qualified as PublicationSpec
import Max.RecallSpec qualified as RecallSpec
import Max.ResourceCapabilitiesSpec qualified as ResourceCapabilitiesSpec
import Max.SandboxRegistrySpec qualified as SandboxRegistrySpec
import Max.SkillWorkflowSpec qualified as SkillWorkflowSpec
import Max.StreamingSpec qualified as StreamingSpec
import Max.WorkflowAgentSpec qualified as WorkflowAgentSpec
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
        WorkflowAgentSpec.spec pool
        SkillWorkflowSpec.spec pool
        ExecutionSpec.spec pool
        AdminTimelineSpec.spec pool
        SessionSpec.spec pool
        TransactionSpec.spec pool
        AgentTurnSpec.spec pool
        JobSpec.spec pool
        ProgressSpec.spec pool
        BrowserSpec.spec pool
        ConnectionSpec.spec pool
        ProjectionSpec.spec pool
        ConversationCursorSpec.spec pool
        ContextAdminSpec.spec pool
        ConversationCapabilitiesSpec.spec pool
        ResourceCapabilitiesSpec.spec pool
        SandboxRegistrySpec.spec pool
        ChatViewSpec.spec pool
        EpisodeStoreSpec.spec pool
        HistorianSpec.spec pool
        HistorySpec.spec pool
        FilesSpec.spec pool
        MemoryCapabilitiesSpec.spec pool
        MemoryStoreSpec.spec pool
        MemoryExpirySpec.spec pool
        MediaSpec.spec pool
        MediaMissingSpec.spec pool
        MonitorSpec.spec pool
        HttpMonitorSpec.spec pool
        MonitorJobsSpec.spec pool
        QQBackfillSpec.spec pool
        RecallSpec.spec pool
        PromptIntegrationSpec.spec pool
        PlatformCapabilitiesSpec.spec pool
        PlatformStoreSpec.spec pool
        PublicationSpec.spec pool
        StreamingSpec.spec pool
      -- Final wipe so a developer running tests against the dev DB
      -- doesn't leave random fixture rows behind.
      truncateAll pool
