-- | Durable ADR 006 monitor state.  E2 implements the first typed slice only:
-- @TimeCron + canned@.  The evaluator commits a pending fire before any
-- outbound publication; a leased worker can then resume that fire after a
-- crash without admitting a second occurrence.
module Max.DB.Monitor
  ( TimeMonitor (..),
    CannedMonitorFire (..),
    monitorDueAt,
    armCannedTimeMonitor,
    listCannedTimeMonitors,
    cancelMonitor,
    nextMonitorDeadline,
    admitDueTimeMonitors,
    claimCannedMonitorFires,
    lookupMonitorFireOutput,
    completeCannedMonitorFire,
    recordMonitorFireFailure,
    reclaimExpiredMonitorFireClaims,
  )
where

import Data.Int (Int64)
import Data.Maybe (fromMaybe, listToMaybe)
import Data.Text (Text)
import Data.Time (UTCTime)
import Database.PostgreSQL.Simple (Only (..))
import Database.PostgreSQL.Simple.FromRow (FromRow (..), field)
import Effectful
import Effectful.PostgreSQL (WithConnection, execute, query)
import Max.ConversationScope (ConversationScope, conversationStorageId)
import Max.DB.Transaction (withTransaction)
import Max.Monitor.Types
import Max.Platform.Types (CanonicalMessageId (..), PrincipalId (..))
import Max.Turn.Types (AgentTurnRef (..))
import OneBot.Types (GroupId (..))

data TimeMonitor = TimeMonitor
  { tmRef :: !MonitorRef,
    tmGroupId :: !Int64,
    tmAuthorPrincipalId :: !(Maybe Int64),
    tmArmingTurn :: !(Maybe AgentTurnRef),
    tmText :: !Text,
    tmCron :: !(Maybe Text),
    tmNextFireAt :: !UTCTime,
    tmCreatedAt :: !UTCTime,
    tmFireCount :: !Int64,
    tmDeliveryAttempts :: !Int,
    tmNextAttemptAt :: !(Maybe UTCTime),
    tmLastError :: !(Maybe Text),
    tmParkedAt :: !(Maybe UTCTime)
  }
  deriving stock (Show, Eq)

instance FromRow TimeMonitor where
  fromRow = do
    monitorId <- field
    ordinal <- field
    groupId <- field
    author <- field
    armingTurnId <- field
    armingTurnOrdinal <- field
    text <- field
    cron <- field
    nextFire <- field
    created <- field
    fireCount <- field
    attempts <- field
    nextAttempt <- field
    lastError <- field
    parked <- field
    pure
      TimeMonitor
        { tmRef = MonitorRef monitorId ordinal,
          tmGroupId = groupId,
          tmAuthorPrincipalId = author,
          tmArmingTurn = AgentTurnRef <$> armingTurnId <*> armingTurnOrdinal,
          tmText = text,
          tmCron = cron,
          tmNextFireAt = nextFire,
          tmCreatedAt = created,
          tmFireCount = fireCount,
          tmDeliveryAttempts = attempts,
          tmNextAttemptAt = nextAttempt,
          tmLastError = lastError,
          tmParkedAt = parked
        }

-- | Effective user-visible deadline: an occurrence in retry/backoff wins over
-- the unchanged schedule time, matching the legacy reminder contract.
monitorDueAt :: TimeMonitor -> UTCTime
monitorDueAt monitor = fromMaybe monitor.tmNextFireAt monitor.tmNextAttemptAt

data CannedMonitorFire = CannedMonitorFire
  { cmfFireId :: !MonitorFireId,
    cmfMonitor :: !MonitorRef,
    cmfGroupId :: !Int64,
    cmfAuthorPrincipalId :: !(Maybe Int64),
    cmfText :: !Text,
    cmfCron :: !(Maybe Text),
    cmfScheduledAt :: !UTCTime,
    cmfDeliveryAttempts :: !Int,
    cmfClaimOwner :: !Text
  }
  deriving stock (Show, Eq)

instance FromRow CannedMonitorFire where
  fromRow =
    CannedMonitorFire
      <$> field
      <*> (MonitorRef <$> field <*> field)
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field

-- | Allocate m# under a conversation-row lock, the same durable alternate-key
-- pattern used for t#.  The optional arming turn is host-derived provenance.
armCannedTimeMonitor ::
  (WithConnection :> es, IOE :> es) =>
  GroupId ->
  PrincipalId ->
  Maybe AgentTurnRef ->
  Text ->
  Maybe Text ->
  UTCTime ->
  Eff es MonitorRef
armCannedTimeMonitor (GroupId legacyGroup) (PrincipalId principal) armingTurn body cron fireAt =
  withTransaction $ do
    conversationRows <-
      query
        "SELECT conversation_id FROM conversations WHERE legacy_group_id = ? FOR UPDATE"
        (Only legacyGroup)
    let conversation = exactlyOne "armCannedTimeMonitor conversation" (conversationRows :: [Only Int64])
    ordinalRows <-
      query
        "SELECT COALESCE(max(monitor_ordinal), 0) + 1 FROM monitors WHERE conversation_id = ?"
        (Only conversation)
    let ordinal = exactlyOne "armCannedTimeMonitor ordinal" (ordinalRows :: [Only MonitorOrdinal])
    rows <-
      query
        "INSERT INTO monitors \
        \ (conversation_id, monitor_ordinal, armed_by_principal_id, arming_turn_id, \
        \  goal_text, trigger_kind, trigger_version, trigger_spec, continuation_kind, \
        \  effect_ceiling, status, schedule_cron, next_fire_at) \
        \ VALUES (?, ?, ?, ?, ?, 'time_cron', 1, \
        \   jsonb_strip_nulls(jsonb_build_object('kind','TimeCron','version',1,'at',?::timestamptz,'cron',?::text)), \
        \   'canned', '{}'::jsonb, 'armed', ?, ?) \
        \ RETURNING monitor_id"
        ( conversation,
          ordinal,
          principal,
          fmap (.atrTurnId) armingTurn,
          body,
          fireAt,
          cron,
          cron,
          fireAt
        )
    pure (MonitorRef (exactlyOne "armCannedTimeMonitor insert" (rows :: [Only MonitorId])) ordinal)

listCannedTimeMonitors ::
  (WithConnection :> es, IOE :> es) =>
  ConversationScope ->
  Eff es [TimeMonitor]
listCannedTimeMonitors scope =
  query
    "SELECT m.monitor_id, m.monitor_ordinal, c.legacy_group_id, m.armed_by_principal_id, \
    \       m.arming_turn_id, arming.turn_ordinal, m.goal_text, m.schedule_cron, \
    \       m.next_fire_at, m.created_at, m.fire_count, \
    \       COALESCE(active.delivery_attempts, 0), active.next_attempt_at, \
    \       active.last_error, active.parked_at \
    \FROM conversations c JOIN monitors m USING (conversation_id) \
    \LEFT JOIN agent_turns arming ON arming.turn_id=m.arming_turn_id AND arming.conversation_id=m.conversation_id \
    \LEFT JOIN LATERAL ( \
    \  SELECT f.delivery_attempts, f.next_attempt_at, f.last_error, f.parked_at \
    \  FROM monitor_fires f WHERE f.monitor_id=m.monitor_id \
    \    AND f.admission_state='pending' AND f.cancelled_at IS NULL \
    \  ORDER BY f.created_at DESC, f.fire_id DESC LIMIT 1 \
    \) active ON true \
    \WHERE c.legacy_group_id=? AND m.status='armed' AND m.trigger_kind='time_cron' \
    \  AND m.continuation_kind='canned' \
    \ORDER BY COALESCE(active.next_attempt_at, m.next_fire_at), m.monitor_ordinal"
    (Only (conversationStorageId scope))

-- | Scope resolution uses m# only inside the current conversation.  Rows are
-- retained as cancelled audit state rather than deleted.
cancelMonitor ::
  (WithConnection :> es, IOE :> es) =>
  ConversationScope ->
  MonitorOrdinal ->
  Eff es Bool
cancelMonitor scope ordinal = withTransaction $ do
  rows <-
    query
      "SELECT m.monitor_id FROM monitors m JOIN conversations c USING (conversation_id) \
      \ WHERE m.conversation_id=c.conversation_id AND c.legacy_group_id=? \
      \   AND m.monitor_ordinal=? AND m.status='armed' \
      \ FOR UPDATE OF m"
      (conversationStorageId scope, ordinal)
  case rows :: [Only MonitorId] of
    [] -> pure False
    [Only monitorId] -> do
      -- If canonical publication won the monitor lock just before cancel,
      -- retain that occurrence as dispatched evidence while stopping every
      -- future occurrence. Publication that loses this lock observes the
      -- cancelled monitor and is rejected by enqueueOutbound instead.
      published <-
        execute
          "UPDATE monitor_fires f SET admission_state='dispatched', dispatched_at=now(), \
          \ outbound_canonical_message_id=msg.canonical_message_id, \
          \ claim_owner=NULL, claim_expires_at=NULL, next_attempt_at=NULL, \
          \ last_error=NULL, parked_at=NULL \
          \ FROM messages msg WHERE f.monitor_id=? AND f.admission_state='pending' \
          \   AND f.cancelled_at IS NULL AND msg.monitor_fire_id=f.fire_id"
          (Only monitorId)
      _ <-
        execute
          "UPDATE monitor_fires SET cancelled_at=now(), claim_owner=NULL, claim_expires_at=NULL \
          \ WHERE monitor_id=? AND admission_state='pending' AND cancelled_at IS NULL"
          (Only monitorId)
      _ <-
        execute
          "UPDATE monitors SET status='cancelled', next_fire_at=NULL, cancelled_at=now(), \
          \ fire_count=fire_count+?, updated_at=now() WHERE monitor_id=?"
          (published, monitorId)
      pure True
    _ -> error "cancelMonitor: duplicate scoped ordinal"

-- | Earliest evaluator, retry, or expired-lease wakeup.  This is a deadline,
-- not polling: the in-memory scheduler sleeps until it or a write-through bell.
nextMonitorDeadline ::
  (WithConnection :> es, IOE :> es) =>
  UTCTime ->
  Eff es (Maybe UTCTime)
nextMonitorDeadline now = do
  rows <-
    query
      "SELECT min(deadline) FROM ( \
      \  SELECT m.next_fire_at AS deadline FROM monitors m \
      \  WHERE m.status='armed' AND m.trigger_kind='time_cron' \
      \    AND m.continuation_kind='canned' \
      \    AND NOT EXISTS (SELECT 1 FROM monitor_fires f WHERE f.monitor_id=m.monitor_id \
      \      AND f.admission_state='pending' AND f.cancelled_at IS NULL) \
      \  UNION ALL \
      \  SELECT CASE WHEN f.claim_expires_at>? THEN f.claim_expires_at \
      \              ELSE COALESCE(f.next_attempt_at, f.created_at) END \
      \  FROM monitor_fires f JOIN monitors m USING (monitor_id) \
      \  WHERE m.status='armed' AND m.continuation_kind='canned' \
      \    AND f.admission_state='pending' AND f.cancelled_at IS NULL \
      \    AND f.parked_at IS NULL \
      \) deadlines"
      (Only now)
  pure $ case rows :: [Only (Maybe UTCTime)] of
    [Only deadline] -> deadline
    _ -> Nothing

-- | Edge-trigger the due schedule into durable pending rows.  Repeating this
-- after a crash is harmless: the active-fire and scheduled-at unique keys are
-- both hard database guards.
admitDueTimeMonitors ::
  (WithConnection :> es, IOE :> es) =>
  UTCTime ->
  Eff es Int64
admitDueTimeMonitors now =
  execute
    "WITH due AS ( \
    \  SELECT m.monitor_id, m.next_fire_at FROM monitors m \
    \  WHERE m.status='armed' AND m.trigger_kind='time_cron' \
    \    AND m.continuation_kind='canned' AND m.next_fire_at<=? \
    \    AND NOT EXISTS (SELECT 1 FROM monitor_fires f WHERE f.monitor_id=m.monitor_id \
    \      AND f.admission_state='pending' AND f.cancelled_at IS NULL) \
    \  FOR UPDATE OF m SKIP LOCKED \
    \) INSERT INTO monitor_fires (monitor_id, idempotency_key, scheduled_at) \
    \SELECT due.monitor_id, \
    \       'time:' || due.monitor_id::text || ':' || extract(epoch FROM due.next_fire_at)::text, \
    \       due.next_fire_at FROM due \
    \ON CONFLICT DO NOTHING"
    (Only now)

claimCannedMonitorFires ::
  (WithConnection :> es, IOE :> es) =>
  Text ->
  UTCTime ->
  UTCTime ->
  Int ->
  Eff es [CannedMonitorFire]
claimCannedMonitorFires owner now leaseExpires limit =
  query
    "WITH candidates AS ( \
    \  SELECT f.fire_id FROM monitor_fires f JOIN monitors m USING (monitor_id) \
    \  WHERE m.status='armed' AND m.continuation_kind='canned' \
    \    AND f.admission_state='pending' AND f.cancelled_at IS NULL \
    \    AND f.parked_at IS NULL \
    \    AND COALESCE(f.next_attempt_at, f.created_at)<=? \
    \    AND (f.claim_owner IS NULL OR f.claim_expires_at<=?) \
    \  ORDER BY COALESCE(f.next_attempt_at, f.created_at), f.fire_id \
    \  FOR UPDATE OF f SKIP LOCKED LIMIT ? \
    \), claimed AS ( \
    \  UPDATE monitor_fires f SET claim_owner=?, claim_expires_at=? \
    \  FROM candidates c WHERE f.fire_id=c.fire_id \
    \  RETURNING f.fire_id, f.monitor_id, f.scheduled_at, f.delivery_attempts, f.claim_owner \
    \) \
    \SELECT claimed.fire_id, m.monitor_id, m.monitor_ordinal, c.legacy_group_id, \
    \       m.armed_by_principal_id, m.goal_text, m.schedule_cron, \
    \       claimed.scheduled_at, claimed.delivery_attempts, claimed.claim_owner \
    \FROM claimed JOIN monitors m USING (monitor_id) JOIN conversations c USING (conversation_id) \
    \ORDER BY claimed.scheduled_at, claimed.fire_id"
    (now, now, max 1 (min 100 limit), owner, leaseExpires)

lookupMonitorFireOutput ::
  (WithConnection :> es, IOE :> es) =>
  MonitorFireId ->
  Eff es (Maybe CanonicalMessageId)
lookupMonitorFireOutput fireId = do
  rows <-
    query
      "SELECT canonical_message_id FROM messages WHERE monitor_fire_id=?"
      (Only fireId)
  pure $ CanonicalMessageId <$> listToMaybe [messageId | Only messageId <- (rows :: [Only Int64])]

-- | Ack the durable fire and advance its schedule in one transaction.  If a
-- crash happened after canonical publication, the worker first rediscovers
-- that message and calls this same CAS; no second outbound row is created.
completeCannedMonitorFire ::
  (WithConnection :> es, IOE :> es) =>
  Text ->
  MonitorFireId ->
  Maybe CanonicalMessageId ->
  Maybe UTCTime ->
  Eff es Bool
completeCannedMonitorFire owner fireId canonical nextFire = withTransaction $ do
  let canonicalId = fmap (.unCanonicalMessageId) canonical
  monitorRows <-
    query
      "SELECT m.monitor_id FROM monitor_fires f JOIN monitors m USING (monitor_id) \
      \ WHERE f.fire_id=? AND f.admission_state='pending' AND f.cancelled_at IS NULL \
      \   AND f.claim_owner=? AND m.status='armed' FOR UPDATE OF m"
      (fireId, owner)
  case monitorRows :: [Only MonitorId] of
    [] -> pure False
    [Only monitorId] -> do
      rows <-
        query
          "UPDATE monitor_fires f SET admission_state='dispatched', dispatched_at=now(), \
          \ outbound_canonical_message_id=?, claim_owner=NULL, claim_expires_at=NULL, \
          \ next_attempt_at=NULL, last_error=NULL, parked_at=NULL \
          \ WHERE f.fire_id=? AND f.admission_state='pending' AND f.cancelled_at IS NULL \
          \   AND f.claim_owner=? \
          \   AND (?::bigint IS NULL OR EXISTS (SELECT 1 FROM messages msg \
          \     WHERE msg.canonical_message_id=? AND msg.monitor_fire_id=f.fire_id)) \
          \ RETURNING f.monitor_id"
          (canonicalId, fireId, owner, canonicalId, canonicalId)
      case rows :: [Only MonitorId] of
        [] -> pure False
        [Only lockedMonitorId]
          | lockedMonitorId == monitorId -> do
              changed <-
                execute
                  "UPDATE monitors SET status=CASE WHEN ?::timestamptz IS NULL THEN 'fired' ELSE 'armed' END, \
                  \ next_fire_at=?, fire_count=fire_count+1, updated_at=now() \
                  \ WHERE monitor_id=? AND status='armed'"
                  (nextFire, nextFire, monitorId)
              pure (changed == 1)
        _ -> error "completeCannedMonitorFire: duplicate fire"
    _ -> error "completeCannedMonitorFire: duplicate fire"

recordMonitorFireFailure ::
  (WithConnection :> es, IOE :> es) =>
  Text ->
  MonitorFireId ->
  Text ->
  Maybe UTCTime ->
  Eff es Bool
recordMonitorFireFailure owner fireId err retryAt = do
  changed <-
    execute
      "UPDATE monitor_fires SET delivery_attempts=delivery_attempts+1, \
      \ next_attempt_at=?, last_error=?, \
      \ parked_at=CASE WHEN ?::timestamptz IS NULL THEN now() ELSE NULL END, \
      \ claim_owner=NULL, claim_expires_at=NULL \
      \ WHERE fire_id=? AND admission_state='pending' AND cancelled_at IS NULL \
      \   AND claim_owner=?"
      (retryAt, err, retryAt, fireId, owner)
  pure (changed == 1)

-- | Boot reconciliation is intentionally conservative: only expired claims
-- are released.  A still-live lease remains the durable ownership fact and
-- naturally wakes at its expiry through 'nextMonitorDeadline'.
reclaimExpiredMonitorFireClaims ::
  (WithConnection :> es, IOE :> es) =>
  UTCTime ->
  Eff es Int64
reclaimExpiredMonitorFireClaims now =
  execute
    "UPDATE monitor_fires SET claim_owner=NULL, claim_expires_at=NULL \
    \ WHERE admission_state='pending' AND claim_expires_at<=?"
    (Only now)

exactlyOne :: Text -> [Only a] -> a
exactlyOne _ [Only value] = value
exactlyOne label _ = error (show label <> ": expected exactly one row")
