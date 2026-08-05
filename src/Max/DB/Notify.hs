-- | Race-free LISTEN/NOTIFY wakeups for durable work queues.
--
-- The listener subscribes before rechecking the queue.  A transaction that
-- publishes work either becomes visible to that recheck or leaves a pending
-- notification, so workers cannot sleep through the commit window.  The
-- bounded timeout is only for expired leases and delayed retries, which do not
-- themselves change a row when they become eligible.
--
-- Every waiter holds exactly one pooled connection: the recheck runs on the
-- pinned listener connection rather than asking the pool for a second one.
-- Otherwise a waiter that already owns a connection blocks — with no timeout —
-- on acquiring another, and enough concurrent waiters (two work channels plus
-- admin long-polls) deadlock the pool against itself.
module Max.DB.Notify
  ( WorkChannel (..),
    claimOrWait,
    waitForTimeline,
  )
where

import Control.Monad (void)
import Data.ByteString.Char8 qualified as BSC
import Data.Int (Int64)
import Database.PostgreSQL.Simple qualified as PostgreSQL
import Database.PostgreSQL.Simple.Notification (Notification (..), getNotification)
import Database.PostgreSQL.Simple.Types (Query)
import Effectful
import Effectful.Exception (bracket_)
import Effectful.PostgreSQL.Connection (WithConnection, withConnection)
import Max.DB.Transaction (withPinnedConnection)
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
    bracket_
      (liftIO (void (PostgreSQL.execute_ listener (listenQuery channel))))
      (liftIO (void (PostgreSQL.execute_ listener (unlistenQuery channel))))
      ( do
          ready <- withPinnedConnection listener claim
          if null ready
            then do
              _ <- liftIO (timeout notificationFallbackMicros (getNotification listener))
              withPinnedConnection listener claim
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

-- | Race-free live-tail wait for the admin ledger. The caller supplies the
-- durable sequence recheck: subscribe first, recheck second, then wait only
-- when the requested conversation is still caught up. A relevant notification
-- means the rendered view changed even when conversation_seq did not (for
-- example a delivery completed); @*@ denotes global backlog/capability state.
-- Notifications for other conversations are ignored inside one bounded
-- request lifetime.
waitForTimeline ::
  (WithConnection :> es, IOE :> es) =>
  Int64 ->
  Eff es Bool ->
  Eff es Bool
waitForTimeline conversation advanced =
  withConnection $ \listener ->
    bracket_
      (liftIO (void (PostgreSQL.execute_ listener "LISTEN max_timeline_work")))
      (liftIO (void (PostgreSQL.execute_ listener "UNLISTEN max_timeline_work")))
      ( do
          ready <- withPinnedConnection listener advanced
          if ready
            then pure True
            else do
              let expected = BSC.pack (show conversation)
                  waitRelevant = do
                    notification <- getNotification listener
                    if notificationData notification `elem` [expected, "*"]
                      then pure ()
                      else waitRelevant
              woke <- liftIO (timeout timelineWaitMicros waitRelevant)
              case woke of
                Nothing -> pure False
                Just () -> pure True
      )

timelineWaitMicros :: Int
timelineWaitMicros = 25 * 1_000_000
