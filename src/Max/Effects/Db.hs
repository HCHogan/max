{-# LANGUAGE TypeFamilies #-}

module Max.Effects.Db
  ( Db,
    runDb,
    withConn,
  )
where

import Data.Pool (Pool, withResource)
import Database.PostgreSQL.Simple (Connection)
import Effectful
import Effectful.Dispatch.Dynamic (interpret, send)

data Db :: Effect where
  WithConn :: (Connection -> IO a) -> Db m a

type instance DispatchOf Db = Dynamic

runDb :: IOE :> es => Pool Connection -> Eff (Db : es) a -> Eff es a
runDb pool = interpret $ \_ -> \case
  WithConn f -> liftIO (withResource pool f)

-- | Run a 'Connection'-using @IO@ action against a pooled connection.
withConn :: Db :> es => (Connection -> IO a) -> Eff es a
withConn f = send (WithConn f)
