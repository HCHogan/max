-- | Race-free LISTEN/NOTIFY wakeups for durable work queues.
--
-- The listener subscribes before rechecking the queue.  A transaction that
-- publishes work either becomes visible to that recheck or leaves a pending
-- notification, so workers cannot sleep through the commit window.  The
-- bounded timeout is only for expired leases and delayed retries, which do not
-- themselves change a row when they become eligible.
module Max.DB.Notify
  ( WorkChannel (..),
    claimOrWait,
  )
where

import Control.Exception (bracket_)
import Control.Monad (void)
import Database.PostgreSQL.Simple qualified as PostgreSQL
import Database.PostgreSQL.Simple.Notification (getNotification)
import Database.PostgreSQL.Simple.Types (Query)
import Effectful
import Effectful.PostgreSQL.Connection (WithConnection, withConnection)
import System.Timeout (timeout)

data WorkChannel = DispatchWork | DeliveryWork
  deriving stock (Eq, Show)

claimOrWait ::
  (WithConnection :> es, IOE :> es) =>
  WorkChannel ->
  Eff es [a] ->
  Eff es [a]
claimOrWait channel claim =
  withConnection $ \listener ->
    withSeqEffToIO $ \run ->
      liftIO $
        bracket_
          (void (PostgreSQL.execute_ listener (listenQuery channel)))
          (void (PostgreSQL.execute_ listener (unlistenQuery channel)))
          ( do
              ready <- run claim
              if null ready
                then do
                  _ <- timeout notificationFallbackMicros (getNotification listener)
                  run claim
                else pure ready
          )

listenQuery :: WorkChannel -> Query
listenQuery = \case
  DispatchWork -> "LISTEN max_dispatch_work"
  DeliveryWork -> "LISTEN max_delivery_work"

unlistenQuery :: WorkChannel -> Query
unlistenQuery = \case
  DispatchWork -> "UNLISTEN max_dispatch_work"
  DeliveryWork -> "UNLISTEN max_delivery_work"

notificationFallbackMicros :: Int
notificationFallbackMicros = 30 * 1_000_000
