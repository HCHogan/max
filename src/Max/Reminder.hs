-- |
-- The reminder scheduler: a single long-lived worker that delivers
-- scheduled reminders (see "Max.DB.Reminder") at their due time and
-- rolls recurring ones forward.
--
-- __Event-driven, not polling.__  The worker asks the DB for the
-- earliest pending reminder and sleeps exactly until that instant,
-- using the same @registerDelay@ + STM @orElse@/@retry@ idiom as
-- 'Max.Effects.NapCat.awaitWithTimeout'.  Adding or cancelling a
-- reminder bumps 'rsSignal' via 'notifyReminderChange', which wakes the
-- sleep early so the schedule is re-evaluated immediately — no periodic
-- scan.  The DB is the single source of truth; the in-memory handle is
-- just a wakeup bell, so reminders survive a restart (the worker
-- re-reads the earliest pending row on startup).
--
-- Recurring reminders carry a cron expression interpreted against the
-- configured display timezone's wall clock.  Because that timezone is a
-- fixed offset (no DST), wall-clock <-> UTC is a constant shift, so
-- 'nextCronFire' is exact and unambiguous.
module Max.Reminder
  ( ReminderScheduler,
    newReminderScheduler,
    notifyReminderChange,
    reminderWorker,
    nextCronFire,
  )
where

import Control.Concurrent.STM
  ( TVar,
    atomically,
    modifyTVar',
    newTVarIO,
    readTVar,
    readTVarIO,
    registerDelay,
    retry,
  )
import Data.Aeson (object, withObject, (.:), (.=))
import Data.Aeson.Types (parseEither)
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time
  ( TimeZone,
    UTCTime,
    diffUTCTime,
    getCurrentTime,
    localTimeToUTC,
    utc,
    utcToLocalTime,
  )
import Effectful
import Effectful.Log (Log, logAttention, logInfo)
import Effectful.PostgreSQL (WithConnection)
import Max.DB.Message (insertOutbound)
import Max.DB.Reminder
  ( Reminder (..),
    dueReminders,
    markFired,
    nextPending,
    rescheduleReminder,
  )
import Max.Effects.NapCat (NapCat, callAction)
import Max.Util (catchSync)
import OneBot.Action (Response (..), sendChatMsg)
import OneBot.Segment (Segment (..))
import OneBot.Types (GroupId (..), MessageId (..), UserId (..), isPrivateChat)
import System.Cron (CronSchedule, nextMatch)
import System.Cron.Parser (parseCronSchedule)

--------------------------------------------------------------------------------
-- Scheduler handle

-- | The in-memory half of the scheduler: a monotonically bumped
-- counter that means "the pending set changed, re-evaluate".  Holds no
-- reminder state itself — the @reminders@ table is authoritative.
newtype ReminderScheduler = ReminderScheduler {rsSignal :: TVar Int}

newReminderScheduler :: IO ReminderScheduler
newReminderScheduler = ReminderScheduler <$> newTVarIO 0

-- | Wake the worker so it re-reads the earliest pending reminder.  Call
-- after inserting or deleting a reminder.
notifyReminderChange :: ReminderScheduler -> IO ()
notifyReminderChange s = atomically (modifyTVar' s.rsSignal (+ 1))

--------------------------------------------------------------------------------
-- Cron

-- | The next UTC instant strictly after @after@ whose /display-timezone
-- wall clock/ matches the cron schedule.  max's display timezone is a
-- fixed offset (no DST), so wall-clock <-> UTC is a constant shift and
-- this round-trips exactly: read @after@'s wall clock, treat those
-- calendar numbers as if UTC, ask cron for the next matching wall
-- clock, then convert that wall clock back to real UTC.
nextCronFire :: TimeZone -> CronSchedule -> UTCTime -> Maybe UTCTime
nextCronFire tz sched after = do
  let pseudo = localTimeToUTC utc (utcToLocalTime tz after)
  pseudoNext <- nextMatch sched pseudo
  pure (localTimeToUTC tz (utcToLocalTime utc pseudoNext))

--------------------------------------------------------------------------------
-- Worker

-- | Cap on a single sleep.  Not a poll interval — near-term reminders
-- always wake precisely.  This only bounds sleeps for far-future
-- reminders so a very long delay can't overflow the microsecond 'Int'
-- and a wall-clock adjustment gets noticed within the hour.
capMicros :: Int
capMicros = 3600 * 1000000

-- | Microseconds to sleep until @fireAt@, clamped to @[0, capMicros]@.
-- Clamps on 'Double' before 'round' so the conversion can't overflow.
delayMicrosFor :: UTCTime -> UTCTime -> Int
delayMicrosFor now fireAt =
  let micros = realToFrac (diffUTCTime fireAt now) * 1e6 :: Double
   in round (max 0 (min (fromIntegral capMicros) micros))

reminderWorker ::
  (WithConnection :> es, NapCat :> es, Log :> es, IOE :> es) =>
  TimeZone ->
  ReminderScheduler ->
  Eff es ()
reminderWorker tz sched = loop
  where
    loop = do
      -- Snapshot the signal *before* querying, so a change landing
      -- between the query and the sleep still wakes us (the counter
      -- won't match this snapshot).
      v0 <- liftIO (readTVarIO sched.rsSignal)
      mNext <- nextPending
      now <- liftIO getCurrentTime
      case mNext of
        Nothing -> do
          liftIO (waitSignal v0)
          loop
        Just r
          | r.rmFireAt <= now -> do
              due <- dueReminders now
              mapM_ (process now) due
              loop
          | otherwise -> do
              liftIO (waitUntil v0 (delayMicrosFor now r.rmFireAt))
              loop

    -- Block until the pending set changes.
    waitSignal v0 = atomically $ do
      v <- readTVar sched.rsSignal
      if v /= v0 then pure () else retry

    -- Block until the timer elapses or the pending set changes.
    waitUntil v0 micros = do
      timer <- registerDelay micros
      atomically $ do
        fired <- readTVar timer
        v <- readTVar sched.rsSignal
        if fired || v /= v0 then pure () else retry

    -- Deliver, then advance past this reminder *unconditionally* — even
    -- if delivery failed (e.g. no client connected), advancing prevents
    -- a persistent failure from hot-looping the scheduler.
    process now r = do
      catchSync (deliver r) $ \e ->
        logAttention "reminder: delivery crashed" $
          object ["id" .= r.rmId, "error" .= T.pack (show e)]
      case r.rmCron of
        Nothing -> markFired r.rmId now
        Just expr -> case parseCronSchedule expr of
          Right s | Just nextAt <- nextCronFire tz s now -> rescheduleReminder r.rmId nextAt
          _ -> do
            logAttention "reminder: cannot advance cron; closing" $
              object ["id" .= r.rmId, "cron" .= expr]
            markFired r.rmId now

    deliver r = do
      let gid = GroupId r.rmGroupId
          segs = deliverySegments gid (UserId r.rmUserId) r.rmText
      eres <- callAction (sendChatMsg gid segs) 30000
      case eres of
        Left err ->
          logAttention "reminder: send failed" $
            object ["id" .= r.rmId, "error" .= err]
        Right (Response _ rc payload _)
          | rc /= 0 ->
              logAttention "reminder: bad retcode" $
                object ["id" .= r.rmId, "retcode" .= rc]
          | otherwise -> do
              case parseEither (withObject "send_resp" (.: "message_id")) payload of
                Right (outMid :: Int64) ->
                  insertOutbound gid (UserId r.rmSelfId) "max" (MessageId outMid) Nothing segs
                Left _ ->
                  logAttention "reminder: no message_id in response" $
                    object ["payload" .= payload]
              logInfo "reminder: sent" $
                object ["id" .= r.rmId, "recurring" .= maybe False (const True) r.rmCron]

-- | @-mention the asker in groups; plain text in private chats (private
-- at-segments render poorly — same reasoning as the @say@ tool).
deliverySegments :: GroupId -> UserId -> Text -> [Segment]
deliverySegments gid uid body
  | isPrivateChat gid = [SegText ("⏰ 提醒：" <> body)]
  | otherwise = [SegAt uid, SegText (" ⏰ 提醒：" <> body)]
