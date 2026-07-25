-- |
-- Entry point for the DB-integration test suite.
--
-- This suite needs a real Postgres database — see test-db/README.md
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
import Max.DB.Connection (DbConfig (..), closeDbPool, newDbPool)
import Max.DB.Migrations (runMigrations)
import Max.DB.FetchQueueSpec qualified as FetchQueueSpec
import Max.DB.HistorySpec qualified as HistorySpec
import Max.DB.MessageSpec qualified as MessageSpec
import Max.DB.SessionSpec qualified as SessionSpec
import Max.PromptIntegrationSpec qualified as PromptIntegrationSpec
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
        SessionSpec.spec pool
        HistorySpec.spec pool
        MessageSpec.spec pool
        FetchQueueSpec.spec pool
        PromptIntegrationSpec.spec pool
      -- Final wipe so a developer running tests against the dev DB
      -- doesn't leave random fixture rows behind.
      truncateAll pool
