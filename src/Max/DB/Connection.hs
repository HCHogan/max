module Max.DB.Connection
  ( DbConfig (..),
    DbPool,
    newDbPool,
    closeDbPool,
    withConn,
  )
where

import Data.ByteString.Char8 qualified as BSC
import Data.Pool (Pool, defaultPoolConfig, destroyAllResources, newPool, setNumStripes, withResource)
import Data.Text (Text)
import Data.Text qualified as T
import Database.PostgreSQL.Simple (Connection, close, connectPostgreSQL)

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

withConn :: DbPool -> (Connection -> IO a) -> IO a
withConn = withResource
