-- |
-- CRUD over the @reminders@ table (migration 016).  Typed SQL only —
-- the scheduling policy (when to fire, how to advance a recurring
-- reminder) lives in "Max.Reminder", and the argument parsing /
-- permission scoping in "Max.Tools.Reminder".
--
-- A reminder is one-shot ('rmCron' == 'Nothing', closed with
-- 'markFired') or recurring ('rmCron' == @Just expr@, kept pending and
-- rolled forward with 'rescheduleReminder'). Delivery retry state is separate
-- from 'rmFireAt', so a transient failure never rewrites the user's schedule.
module Max.DB.Reminder
  ( Reminder (..),
    reminderDueAt,
    insertReminder,
    dueReminders,
    nextPending,
    markFired,
    rescheduleReminder,
    recordDeliveryFailure,
    listPending,
    cancelReminder,
  )
where

import Data.Int (Int64)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Time (UTCTime)
import Database.PostgreSQL.Simple (Only (..), Query)
import Database.PostgreSQL.Simple.FromRow (FromRow, field, fromRow)
import Effectful
import Effectful.PostgreSQL (WithConnection, execute, query)
import OneBot.Types (GroupId (..), UserId (..))

-- | One scheduled reminder.  'rmCron' distinguishes one-shot
-- ('Nothing') from recurring (@Just@ a 5-field cron expression,
-- interpreted against the display timezone).
data Reminder = Reminder
  { rmId :: !Int64,
    rmGroupId :: !Int64,
    rmUserId :: !Int64,
    rmSelfId :: !Int64,
    rmText :: !Text,
    rmCron :: !(Maybe Text),
    rmFireAt :: !UTCTime,
    rmCreatedAt :: !UTCTime,
    rmDeliveryAttempts :: !Int,
    rmNextAttemptAt :: !(Maybe UTCTime),
    rmLastError :: !(Maybe Text),
    rmParkedAt :: !(Maybe UTCTime)
  }
  deriving stock (Show, Eq)

instance FromRow Reminder where
  fromRow =
    Reminder
      <$> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field

-- | Column list matching 'FromRow', for every SELECT below.
selectCols :: Query
selectCols =
  "id, group_id, user_id, self_id, text, cron_expr, fire_at, created_at, \
  \delivery_attempts, next_attempt_at, last_error, parked_at"

-- | Effective scheduler deadline: the original/next cron fire unless a
-- delivery retry is pending.
reminderDueAt :: Reminder -> UTCTime
reminderDueAt r = fromMaybe r.rmFireAt r.rmNextAttemptAt

-- | Insert a reminder, returning its new id.
insertReminder ::
  (WithConnection :> es, IOE :> es) =>
  GroupId ->
  UserId -> -- who asked
  UserId -> -- bot self_id
  Text -> -- reminder body
  Maybe Text -> -- cron expression; 'Nothing' = one-shot
  UTCTime -> -- first (or only) fire time
  Eff es Int64
insertReminder (GroupId gid) (UserId uid) (UserId sid) body cron fireAt = do
  rows <-
    query
      "INSERT INTO reminders (group_id, user_id, self_id, text, cron_expr, fire_at) \
      \  VALUES (?, ?, ?, ?, ?, ?) RETURNING id"
      (gid, uid, sid, body, cron, fireAt)
  pure $ case rows of
    [Only n] -> n
    _ -> 0 -- unreachable: RETURNING on a successful insert yields one row

-- | Every deliverable reminder due at or before @now@, earliest first.
-- The scheduler drains these in one shot so a backlog accrued while
-- the process was down is delivered together.
dueReminders ::
  (WithConnection :> es, IOE :> es) =>
  UTCTime ->
  Eff es [Reminder]
dueReminders now =
  query
    ( "SELECT " <> selectCols <> " FROM reminders \
      \  WHERE fired_at IS NULL AND parked_at IS NULL \
      \    AND COALESCE(next_attempt_at, fire_at) <= ? \
      \  ORDER BY COALESCE(next_attempt_at, fire_at)"
    )
    (Only now)

-- | The single earliest deliverable reminder, if any — parked rows stay
-- visible to the list/cancel tools but do not wake the worker.
nextPending ::
  (WithConnection :> es, IOE :> es) =>
  Eff es (Maybe Reminder)
nextPending = do
  rows <-
    query
      ( "SELECT " <> selectCols <> " FROM reminders \
        \  WHERE fired_at IS NULL AND parked_at IS NULL \
        \  ORDER BY COALESCE(next_attempt_at, fire_at) LIMIT 1"
      )
      ()
  pure $ case rows of
    (r : _) -> Just r
    [] -> Nothing

-- | Close out a one-shot reminder after delivery.
markFired ::
  (WithConnection :> es, IOE :> es) =>
  Int64 ->
  UTCTime ->
  Eff es ()
markFired rid firedAt = do
  _ <-
    execute
      "UPDATE reminders SET fired_at = ?, next_attempt_at = NULL, \
      \ delivery_attempts = 0, last_error = NULL, parked_at = NULL WHERE id = ?"
      (firedAt, rid)
  pure ()

-- | Roll a recurring reminder forward to its next fire time; the row
-- stays pending.
rescheduleReminder ::
  (WithConnection :> es, IOE :> es) =>
  Int64 ->
  UTCTime ->
  Eff es ()
rescheduleReminder rid nextAt = do
  _ <-
    execute
      "UPDATE reminders SET fire_at = ?, next_attempt_at = NULL, \
      \ delivery_attempts = 0, last_error = NULL, parked_at = NULL WHERE id = ?"
      (nextAt, rid)
  pure ()

-- | Record one failed delivery. 'Nothing' parks the reminder; 'Just' is the
-- durable retry deadline. The caller owns the bounded backoff policy.
recordDeliveryFailure ::
  (WithConnection :> es, IOE :> es) =>
  Int64 ->
  Text ->
  Maybe UTCTime ->
  Eff es ()
recordDeliveryFailure rid err mRetryAt = do
  _ <-
    execute
      "UPDATE reminders \
      \   SET delivery_attempts = delivery_attempts + 1, \
      \       next_attempt_at = ?, last_error = ?, \
      \       parked_at = CASE WHEN ?::timestamptz IS NULL THEN now() ELSE NULL END \
      \ WHERE id = ? AND fired_at IS NULL"
      (mRetryAt, err, mRetryAt, rid)
  pure ()

-- | Pending reminders for one conversation, earliest first — backs the
-- @list_reminders@ tool.
listPending ::
  (WithConnection :> es, IOE :> es) =>
  GroupId ->
  Eff es [Reminder]
listPending (GroupId gid) =
  query
    ( "SELECT " <> selectCols <> " FROM reminders \
      \  WHERE group_id = ? AND fired_at IS NULL \
      \  ORDER BY COALESCE(next_attempt_at, fire_at)"
    )
    (Only gid)

-- | Delete one pending reminder, scoped to its conversation so a group
-- can't cancel another group's reminder.  'False' when the id is
-- unknown / already fired / not in this group.
cancelReminder ::
  (WithConnection :> es, IOE :> es) =>
  GroupId ->
  Int64 ->
  Eff es Bool
cancelReminder (GroupId gid) rid = do
  n <-
    execute
      "DELETE FROM reminders WHERE id = ? AND group_id = ? AND fired_at IS NULL"
      (rid, gid)
  pure (n > 0)
