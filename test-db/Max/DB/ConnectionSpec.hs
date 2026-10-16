{-# LANGUAGE OverloadedStrings #-}

-- | Issue #17: the pool acquire was the one wait in the process with no
-- ceiling over it, and it was process-wide rather than confined to whatever
-- caused the saturation.  Every other bound max has — the LLM call, a turn's
-- silence, a fork child's budget — sat above a wait that could outlast them
-- all, so this is the test that the floor exists.
module Max.DB.ConnectionSpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (cancel, withAsync)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (bracket)
import Control.Monad (void)
import Data.String (fromString)
import Data.Text qualified as T
import Database.PostgreSQL.Simple (Only (..), execute_, query)
import GHC.Clock (getMonotonicTimeNSec)
import Max.DB.Connection (DbConfig (..), DbPool, PoolTimeout (..), closeDbPool, newDbPool, withConn, withConnTimeout)
import System.Environment (lookupEnv)
import Test.Hspec

-- | Takes the suite's pool for signature uniformity and does not use it: the
-- point is a pool small enough to saturate on purpose, which the shared one is
-- not.
spec :: DbPool -> Spec
spec _ = describe "Max.DB.Connection" $ do
  it "gives up on a saturated pool rather than waiting on it forever" $ do
    lookupEnv "MAX_TEST_DB_URL" >>= \case
      Nothing -> pendingWith "MAX_TEST_DB_URL unset"
      Just url ->
        bracket (newDbPool (DbConfig (T.pack url) 1)) closeDbPool $ \small -> do
          held <- newEmptyMVar
          release <- newEmptyMVar
          -- One connection, taken and kept: the pool is now exactly as
          -- saturated as production was when four LISTEN waiters sat in a pool
          -- of eight, and every later caller is in the state this bounds.
          withAsync (withConn small (\_ -> putMVar held () >> takeMVar release)) $ \_ -> do
            takeMVar held
            withConnTimeout 1 small (\_ -> pure ())
              `shouldThrow` (\(PoolTimeout secs) -> secs == 1)
            putMVar release ()

  -- A tool deadline cancelled context_search while its query kept running on
  -- the server for hours, holding a lock that later blocked a migration.
  it "ends the server-side query when its caller is cancelled" $ do
    lookupEnv "MAX_TEST_DB_URL" >>= \case
      Nothing -> pendingWith "MAX_TEST_DB_URL unset"
      Just url ->
        bracket (newDbPool (DbConfig (T.pack url) 2)) closeDbPool $ \pool -> do
          -- Unique per run, so a probe left by an earlier run cannot match.
          probe <- ("cancelled-caller-probe-" <>) . show <$> getMonotonicTimeNSec
          let running = withConn pool $ \conn -> do
                [Only count] <- query conn "SELECT count(*)::int FROM pg_stat_activity WHERE pid <> pg_backend_pid() AND state = 'active' AND query LIKE ?" (Only ("%" <> probe <> "%"))
                pure (count :: Int)
              waitFor wanted tries = do
                count <- running
                if count == wanted || tries <= (0 :: Int)
                  then pure count
                  else threadDelay 500_000 >> waitFor wanted (tries - 1)
          withAsync (withConn pool (\conn -> void (execute_ conn (fromString ("SELECT pg_sleep(300) /* " <> probe <> " */"))))) $ \caller -> do
            waitFor 1 20 `shouldReturn` 1
            cancel caller
          -- The connection check runs every ten seconds.
          waitFor 0 40 `shouldReturn` 0
