-- |
-- The reminder scheduler: a single long-lived worker that delivers
-- scheduled reminders (see "Max.DB.Reminder") at their due time and
-- rolls recurring ones forward.
--
-- __Event-driven, not polling.__  The worker asks the DB for the
-- earliest pending reminder and sleeps exactly until that instant,
-- using the same @registerDelay@ + STM @orElse@/@retry@ idiom as
-- 'Max.Effects.PlatformApi.awaitWithTimeout'.  Adding or cancelling a
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
    ReminderRetry (..),
    maxReminderAttempts,
    reminderRetryDecision,
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
import Control.Monad (unless)
import Data.Aeson (object, (.=))
import Data.Maybe (isJust)
import Data.Ord (clamp)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time
  ( TimeZone,
    UTCTime,
    addUTCTime,
    diffUTCTime,
    getCurrentTime,
    localTimeToUTC,
    utc,
    utcToLocalTime,
  )
import Effectful
import Effectful.Log (Log, logAttention, logInfo)
import Effectful.PostgreSQL (WithConnection)
import Max.MessageKind (MessageKind (KindChat))
import Max.DB.Reminder
  ( Reminder (..),
    dueReminders,
    markFired,
    nextPending,
    recordDeliveryFailure,
    reminderDueAt,
    rescheduleReminder,
  )
import Max.Effects.Outbound (Outbound, OutboundDeliveryScope (..), OutboundRequest (..), SendOutcome (..), sendRecorded)
import Max.IR (Body (..), Node (..), Phase (Ingest))
import Max.Platform.Types (NativeUserId (..))
import Max.Util (catchSync)
import OneBot.Types (GroupId (..), UserId (..), isPrivateChat)
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
   in round (clamp (0, fromIntegral capMicros) micros)

-- | Five failed external deliveries park a reminder for diagnosis instead of
-- retrying forever. The four retry delays are deliberately bounded and much
-- shorter than the normal one-hour scheduler sleep cap.
maxReminderAttempts :: Int
maxReminderAttempts = 5

data ReminderRetry
  = RetryReminderAt !UTCTime
  | ParkReminder
  deriving stock (Show, Eq)

reminderRetryDecision :: UTCTime -> Int -> ReminderRetry
reminderRetryDecision now failedAttempt
  | failedAttempt >= maxReminderAttempts = ParkReminder
  | otherwise = RetryReminderAt (addUTCTime (fromIntegral delaySecs) now)
  where
    delaySecs :: Int
    delaySecs = case failedAttempt of
      1 -> 30
      2 -> 120
      3 -> 600
      _ -> 1800

reminderWorker ::
  (WithConnection :> es, Outbound :> es, Log :> es, IOE :> es) =>
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
          | reminderDueAt r <= now -> do
              due <- dueReminders now
              mapM_ (process now) due
              loop
          | otherwise -> do
              liftIO (waitUntil v0 (delayMicrosFor now (reminderDueAt r)))
              loop

    -- Block until the pending set changes.
    waitSignal v0 = atomically $ do
      v <- readTVar sched.rsSignal
      unless (v /= v0) retry

    -- Block until the timer elapses or the pending set changes.
    waitUntil v0 micros = do
      timer <- registerDelay micros
      atomically $ do
        fired <- readTVar timer
        v <- readTVar sched.rsSignal
        unless (fired || v /= v0) retry

    -- Delivery is the claim/ack boundary. Only confirmed platform delivery
    -- advances the schedule; failures persist a bounded retry deadline.
    process now r = do
      delivery <-
        catchSync (deliver r) $ \e ->
          pure (Left (T.pack (show e)))
      case delivery of
        Left err -> failDelivery now r err
        Right () -> advance now r

    advance now r = case r.rmCron of
      Nothing -> markFired r.rmId now
      Just expr -> case parseCronSchedule expr of
        Right s | Just nextAt <- nextCronFire tz s now -> rescheduleReminder r.rmId nextAt
        _ -> do
          logAttention "reminder: cannot advance cron; closing" $
            object ["id" .= r.rmId, "cron" .= expr]
          markFired r.rmId now

    failDelivery now r err = do
      let failedAttempt = r.rmDeliveryAttempts + 1
      case reminderRetryDecision now failedAttempt of
        RetryReminderAt retryAt -> do
          recordDeliveryFailure r.rmId err (Just retryAt)
          logAttention "reminder: delivery retry scheduled" $
            object
              [ "id" .= r.rmId,
                "attempt" .= failedAttempt,
                "retry_at" .= retryAt,
                "error" .= err
              ]
        ParkReminder -> do
          recordDeliveryFailure r.rmId err Nothing
          logAttention "reminder: delivery parked" $
            object
              [ "id" .= r.rmId,
                "attempts" .= failedAttempt,
                "error" .= err
              ]

    deliver r = do
      let gid = GroupId r.rmGroupId
          body = deliveryBody gid (UserId r.rmUserId) r.rmText
      outcome <-
        sendRecorded
          OutboundRequest
            { orKind = KindChat,
              orGroupId = gid,
              orBody = body,
              orReplyTo = Nothing,
              orDeliveryScope = DeliverConversation
            }
      case outcome of
        SendFailed err -> pure (Left err)
        SentUnrecorded {} -> Right () <$ sentLog r
        SentRecorded {} -> Right () <$ sentLog r

    sentLog r =
      logInfo "reminder: sent" $
        object ["id" .= r.rmId, "recurring" .= isJust r.rmCron]

-- | @-mention the asker in groups; plain text in private chats (private
-- at-segments render poorly — same reasoning as the @say@ tool).
deliveryBody :: GroupId -> UserId -> Text -> Body 'Ingest
deliveryBody gid (UserId uid) body
  | isPrivateChat gid = Body [NText ("⏰ 提醒：" <> body)]
  | otherwise =
      let native = T.pack (show uid)
       in Body [NMention (NativeUserId native) native, NText (" ⏰ 提醒：" <> body)]
