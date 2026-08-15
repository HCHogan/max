{-# LANGUAGE OverloadedStrings #-}

-- | Issue #17: the pool acquire was the one wait in the process with no
-- ceiling over it, and it was process-wide rather than confined to whatever
-- caused the saturation.  Every other bound max has — the LLM call, a turn's
-- silence, a fork child's budget — sat above a wait that could outlast them
-- all, so this is the test that the floor exists.
module Max.DB.ConnectionSpec (spec) where

import Control.Concurrent.Async (withAsync)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (bracket)
import Data.Text qualified as T
import Max.DB.Connection (DbConfig (..), DbPool, PoolTimeout (..), closeDbPool, newDbPool, withConn, withConnTimeout)
import System.Environment (lookupEnv)
import Test.Hspec

-- | Takes the suite's pool for signature uniformity and does not use it: the
-- point is a pool small enough to saturate on purpose, which the shared one is
-- not.
spec :: DbPool -> Spec
spec _ = describe "Max.DB.Connection" $
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
