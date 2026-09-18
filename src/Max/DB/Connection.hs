-- | PostgreSQL pool with bounded connection acquisition. Pool exhaustion
-- raises an exception instead of leaving a caller waiting indefinitely.
module Max.DB.Connection
  ( DbConfig (..),
    DbPool,
    PoolTimeout (..),
    newDbPool,
    closeDbPool,
    withConn,
    withConnTimeout,
  )
where

import Control.Exception (Exception (..), mask, onException, throwIO)
import Data.ByteString.Char8 qualified as BSC
import Data.Pool (Pool, defaultPoolConfig, destroyAllResources, destroyResource, newPool, putResource, setNumStripes, takeResource)
import Data.Text (Text)
import Data.Text qualified as T
import Database.PostgreSQL.Simple (Connection, close, connectPostgreSQL)
import System.Timeout (timeout)

data DbConfig = DbConfig
  { url :: !Text,
    maxConns :: !Int
  }
  deriving stock (Show, Eq)

type DbPool = Pool Connection

newDbPool :: DbConfig -> IO DbPool
newDbPool cfg =
  newPool $
    setNumStripes (Just 1) $
      defaultPoolConfig
        (connectPostgreSQL (BSC.pack (T.unpack cfg.url)))
        close
        60.0
        cfg.maxConns

closeDbPool :: DbPool -> IO ()
closeDbPool = destroyAllResources

-- | Nobody freed a connection in time.
newtype PoolTimeout = PoolTimeout {poolTimeoutSeconds :: Int}
  deriving stock (Eq, Show)

instance Exception PoolTimeout where
  displayException (PoolTimeout secs) =
    "no Postgres connection became free within "
      <> show secs
      <> "s; the pool is saturated (see MAX_DB_MAX_CONNS and Max.DB.Notify's LISTEN holders)"

-- | How long to wait for a free connection before giving up.
--
-- A backstop, not a tuning knob.  A healthy acquire is immediate; anything
-- that waits seconds means the pool is already saturated, and the only
-- question is whether max reports that or hangs on it.  Long enough that a
-- burst of concurrent turns rides it out, short enough that a leak surfaces
-- while somebody is still looking at the logs.
acquireTimeoutSeconds :: Int
acquireTimeoutSeconds = 30

-- | Bound connection acquisition, not the work performed with it.
-- Data.Pool cleans up interrupted waiters and returns any concurrently acquired
-- resource, so an acquisition timeout cannot strand a connection.
withConn :: DbPool -> (Connection -> IO a) -> IO a
withConn = withConnTimeout acquireTimeoutSeconds

-- | 'withConn' with the deadline named, so a test can prove the bound exists
-- without waiting out the production one.
withConnTimeout :: Int -> DbPool -> (Connection -> IO a) -> IO a
withConnTimeout seconds pool act = mask $ \unmask -> do
  taken <- timeout (seconds * 1_000_000) (takeResource pool)
  case taken of
    Nothing -> throwIO (PoolTimeout seconds)
    Just (conn, localPool) -> do
      r <- unmask (act conn) `onException` destroyResource pool localPool conn
      putResource localPool conn
      pure r
