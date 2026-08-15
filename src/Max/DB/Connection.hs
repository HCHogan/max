-- | The process's Postgres connection pool.
--
-- __Acquiring is bounded__ (issue #17).  'Data.Pool.withResource' waits for a
-- free connection with no deadline, which made pool exhaustion the one
-- unbounded wait in max: not a slow turn but a permanently stopped one, and
-- process-wide rather than confined to the conversation that caused it.  Every
-- other ceiling in the system — the LLM call, a turn's silence, a fork child's
-- budget — sat above a wait that could outlast all of them.
--
-- Failing to get a connection is now an exception, which is the honest answer:
-- something is holding more of the pool than it should, and a caller that
-- learns this can crash its turn, log, and let the next one through, while a
-- caller that waits forever teaches nobody anything.
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
  deriving stock (Show)

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

-- | 'Data.Pool.withResource' with a deadline on the acquire and none on the
-- work, which is the split that matters: bounding the whole thing would kill
-- legitimately slow queries, and bounding neither is what this replaces.
--
-- Interrupting the wait is safe by the library's own construction —
-- @waitForResource@ installs an @onException@ that de-registers the waiter and
-- hands on any resource that arrived while it was unwinding — so a timed-out
-- caller cannot strand a connection.
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
