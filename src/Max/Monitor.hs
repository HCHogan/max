-- | A single scheduler consumes trigger markers and hands each automation fire
-- to the foreground through Jobs. Startup interrupts unfinished triggers;
-- there is no lease or replay worker.
module Max.Monitor (monitorWorker, nextCronFire) where

import Data.Aeson (object, (.=))
import Data.List (unsnoc)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes, maybeToList)
import Data.Time (UTCTime, addUTCTime, diffUTCTime, getCurrentTime)
import Effectful
import Effectful.Log (Log, logAttention)
import Effectful.PostgreSQL (WithConnection)
import Max.DB.Monitor
import Max.DB.Notify (WorkChannel (MonitorWork), waitForWorkUntil)
import Max.Monitor.Schedule (nextCronFire)
import Max.Monitor.Types (MonitorDispatchResult (..), MonitorFireId (..))
import Max.Util (catchSync)
import Max.Worker (recovering)

-- A small floor prevents busy looping when cancellation or a budget check
-- invalidates work between the deadline query and dispatch.
delayMicrosFor :: UTCTime -> UTCTime -> Int
delayMicrosFor now deadline = max 50000 (min 3600000000 (round (diffUTCTime deadline now * 1000000)))

monitorWorker ::
  (WithConnection :> es, Log :> es, IOE :> es) =>
  (ElaboratedMonitorFire -> Eff es MonitorDispatchResult) -> Eff es ()
monitorWorker dispatch = loop Map.empty (MonitorFireId 0)
  where
    loop deferred cursor = recovering "monitor scheduling" (tick deferred cursor) >>= uncurry loop

    tick deferred cursor = do
      now <- liftIO getCurrentTime
      let waiting = Map.filter (> now) deferred
      calendar <- nextMonitorDeadline now (Map.keys waiting)
      let deadlines = maybeToList calendar <> Map.elems waiting
          delay = if null deadlines then 3600000000 else delayMicrosFor now (minimum deadlines)
      work <- waitForWorkUntil delay MonitorWork (readyWork (Map.keys waiting) cursor)
      rechecks <- catMaybes <$> traverse processWork work
      completed <- liftIO getCurrentTime
      let pending = Map.fromList [(fire, addUTCTime 5 completed) | fire <- rechecks] <> waiting
          nextCursor = maybe cursor ((.emfFireId) . snd) (unsnoc work)
      pure (pending, nextCursor)

    readyWork deferred cursor = do
      now <- liftIO getCurrentTime
      _ <- admitDueTimeMonitors now
      pendingElaboratedMonitorFires now deferred cursor 50

    processWork fire =
      (dispatch fire >>= \case MonitorHandled -> pure Nothing; MonitorRecheck -> pure (Just fire.emfFireId))
        `catchSync` \err -> do
          logAttention "monitor check failed; deferred locally" (object ["fire_id" .= fire.emfFireId.unMonitorFireId, "error" .= show err])
          pure (Just fire.emfFireId)
