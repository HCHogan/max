-- | Durable ADR 006 monitor state. Evaluators commit a pending fire before
-- any continuation work; a leased worker can then resume that fire after a
-- crash without admitting a second occurrence or turn.
module Max.DB.Monitor
  ( TimeMonitor (..),
    CannedMonitorFire (..),
    ElaboratedMonitorFire (..),
    ArmedMonitor (..),
    MonitorArmError (..),
    monitorDueAt,
    armCannedTimeMonitor,
    armElaboratedTimeMonitor,
    armLedgerMatchMonitor,
    listCannedTimeMonitors,
    listArmedMonitors,
    cancelMonitor,
    nextMonitorDeadline,
    admitDueTimeMonitors,
    evaluateLedgerMatches,
    claimCannedMonitorFires,
    claimElaboratedMonitorFires,
    admitElaboratedMonitorTurn,
    expireElaboratedMonitorFire,
    loadAdmittedMonitorFire,
    lookupMonitorFireOutput,
    completeCannedMonitorFire,
    recordMonitorFireFailure,
    reclaimExpiredMonitorFireClaims,
  )
where

import Control.Monad (forM, forM_, unless, when)
import Data.Aeson (Value, eitherDecodeStrict', object, (.=))
import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Either (fromRight)
import Data.Maybe (fromMaybe, isNothing, listToMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime)
import Database.PostgreSQL.Simple (Only (..), Query)
import Database.PostgreSQL.Simple.FromRow (FromRow (..), field)
import Database.PostgreSQL.Simple.ToField (ToField (..), toJSONField)
import Database.PostgreSQL.Simple.Types (PGArray (..))
import Effectful
import Effectful.PostgreSQL (WithConnection, execute, query)
import Max.ConversationScope (ConversationScope, conversationStorageId)
import Max.DB.Transaction (withTransaction)
import Max.IR (Body, Phase (Canonical))
import Max.Monitor.Types
import Max.Platform.Types (CanonicalMessageId (..), PrincipalId (..), PrincipalIdentityId)
import Max.Turn.Types (AgentTurnId, AgentTurnRef (..), TurnOrdinal (..))
import OneBot.Types (GroupId (..))

newtype Jsonb = Jsonb Value

instance ToField Jsonb where
  toField (Jsonb value) = toJSONField value

data MonitorArmError
  = ArmedMonitorCapReached
  | ConditionMonitorCapReached
  | ArmingTurnOutsideConversation
  deriving stock (Show, Eq)

data ArmedMonitor = ArmedMonitor
  { amRef :: !MonitorRef,
    amGoal :: !Text,
    amTriggerKind :: !Text,
    amContinuationKind :: !Text,
    amNextFireAt :: !(Maybe UTCTime),
    amExpiresAt :: !(Maybe UTCTime),
    amFireCount :: !Int64,
    amMaxFireCount :: !(Maybe Int64),
    amCreatedAt :: !UTCTime
  }
  deriving stock (Show, Eq)

instance FromRow ArmedMonitor where
  fromRow =
    ArmedMonitor
      <$> (MonitorRef <$> field <*> field)
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field

data ElaboratedMonitorFire = ElaboratedMonitorFire
  { emfFireId :: !MonitorFireId,
    emfMonitor :: !MonitorRef,
    emfGroupId :: !Int64,
    emfArmedByPrincipal :: !PrincipalId,
    emfArmingTurn :: !(Maybe AgentTurnRef),
    -- | The arming principal's own live inbound row, replayed as the fresh
    -- turn's dispatch identity.  'Nothing' is a fail-closed state, not a
    -- normal one: the fire expires with a reason instead of disappearing.
    emfSeedCanonicalMessage :: !(Maybe CanonicalMessageId),
    emfGoal :: !Text,
    emfTriggerKind :: !Text,
    emfCron :: !(Maybe Text),
    emfScheduledAt :: !UTCTime,
    emfTriggerCanonicalMessage :: !(Maybe CanonicalMessageId),
    emfTriggerEvidence :: !Text,
    emfEffectToolGrants :: !(Map Text Text),
    emfRequiredRole :: !Text,
    emfClaimOwner :: !(Maybe Text),
    emfAdmittedTurn :: !(Maybe AgentTurnRef)
  }
  deriving stock (Show, Eq)

instance FromRow ElaboratedMonitorFire where
  fromRow = do
    fireId <- field
    monitor <- MonitorRef <$> field <*> field
    groupId <- field
    principal <- PrincipalId <$> field
    armingTurnId <- field
    armingOrdinal <- field
    seed <- fmap CanonicalMessageId <$> field
    goal <- field
    triggerKind <- field
    cron <- field
    scheduled <- field
    trigger <- fmap CanonicalMessageId <$> field
    evidence <- field
    encodedToolGrants <- field
    requiredRole <- field
    claimOwner <- field
    admittedTurnId <- field
    admittedTurnOrdinal <- field
    pure
      ElaboratedMonitorFire
        { emfFireId = fireId,
          emfMonitor = monitor,
          emfGroupId = groupId,
          emfArmedByPrincipal = principal,
          emfArmingTurn = AgentTurnRef <$> armingTurnId <*> armingOrdinal,
          emfSeedCanonicalMessage = seed,
          emfGoal = goal,
          emfTriggerKind = triggerKind,
          emfCron = cron,
          emfScheduledAt = scheduled,
          emfTriggerCanonicalMessage = trigger,
          emfTriggerEvidence = evidence,
          emfEffectToolGrants =
            fromRight Map.empty (eitherDecodeStrict' (TE.encodeUtf8 encodedToolGrants)),
          emfRequiredRole = requiredRole,
          emfClaimOwner = claimOwner,
          emfAdmittedTurn = AgentTurnRef <$> admittedTurnId <*> admittedTurnOrdinal
        }

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

armElaboratedTimeMonitor ::
  (WithConnection :> es, IOE :> es) =>
  GroupId ->
  PrincipalId ->
  AgentTurnRef ->
  Text ->
  Maybe Text ->
  UTCTime ->
  Map Text Text ->
  Eff es (Either MonitorArmError MonitorRef)
armElaboratedTimeMonitor group principal armingTurn goal cron fireAt toolGrants =
  armElaboratedMonitor
    group
    principal
    armingTurn
    goal
    "time_cron"
    ( object
        [ "kind" .= ("TimeCron" :: Text),
          "version" .= (1 :: Int),
          "at" .= fireAt,
          "cron" .= cron
        ]
    )
    cron
    (Just fireAt)
    0
    Nothing
    Nothing
    toolGrants

armLedgerMatchMonitor ::
  (WithConnection :> es, IOE :> es) =>
  GroupId ->
  PrincipalId ->
  AgentTurnRef ->
  Text ->
  LedgerMatchSpec ->
  Int ->
  UTCTime ->
  Int64 ->
  Map Text Text ->
  Eff es (Either MonitorArmError MonitorRef)
armLedgerMatchMonitor group principal armingTurn goal spec cooldown expires maxFires toolGrants =
  armElaboratedMonitor
    group
    principal
    armingTurn
    goal
    "ledger_match"
    (ledgerMatchSpecValue spec)
    Nothing
    Nothing
    (max 0 cooldown)
    (Just expires)
    (Just (max 1 maxFires))
    toolGrants

armElaboratedMonitor ::
  (WithConnection :> es, IOE :> es) =>
  GroupId ->
  PrincipalId ->
  AgentTurnRef ->
  Text ->
  Text ->
  Value ->
  Maybe Text ->
  Maybe UTCTime ->
  Int ->
  Maybe UTCTime ->
  Maybe Int64 ->
  Map Text Text ->
  Eff es (Either MonitorArmError MonitorRef)
armElaboratedMonitor (GroupId legacyGroup) (PrincipalId principal) armingTurn goal triggerKind triggerSpec cron nextFire cooldown expires maxFires toolGrants =
  withTransaction $ do
    conversationRows <-
      query
        "SELECT conversation_id FROM conversations WHERE legacy_group_id=? FOR UPDATE"
        (Only legacyGroup)
    let conversation = exactlyOne "armElaboratedMonitor conversation" (conversationRows :: [Only Int64])
    armingRows <-
      query
        "SELECT 1 FROM agent_turns WHERE turn_id=? AND conversation_id=?"
        (armingTurn.atrTurnId, conversation)
    case armingRows :: [Only Int] of
      [] -> pure (Left ArmingTurnOutsideConversation)
      [_] -> do
        capRows <-
          query
            "SELECT count(*), count(*) FILTER (WHERE trigger_kind<>'time_cron') \
            \ FROM monitors WHERE conversation_id=? AND status='armed'"
            (Only conversation)
        let (armedCount, conditionCount) = case capRows :: [(Int64, Int64)] of
              [counts] -> counts
              _ -> error "armElaboratedMonitor: cap count"
        if armedCount >= 20
          then pure (Left ArmedMonitorCapReached)
          else
            if triggerKind /= "time_cron" && conditionCount >= 5
              then pure (Left ConditionMonitorCapReached)
              else do
                ordinalRows <-
                  query
                    "SELECT COALESCE(max(monitor_ordinal),0)+1 FROM monitors WHERE conversation_id=?"
                    (Only conversation)
                frontierRows <-
                  query
                    "SELECT COALESCE(max(ingest_seq),0) FROM messages WHERE conversation_id=?"
                    (Only conversation)
                let ordinal = exactlyOne "armElaboratedMonitor ordinal" (ordinalRows :: [Only MonitorOrdinal])
                    frontier = exactlyOne "armElaboratedMonitor frontier" (frontierRows :: [Only Int64])
                    effectCeiling = object ["tool_grants" .= toolGrants]
                rows <-
                  query
                    "INSERT INTO monitors \
                    \ (conversation_id, monitor_ordinal, armed_by_principal_id, arming_turn_id, \
                    \  goal_text, trigger_kind, trigger_version, trigger_spec, continuation_kind, \
                    \  effect_ceiling, status, schedule_cron, next_fire_at, armed_ingest_seq, \
                    \  cooldown_seconds, expires_at, max_fire_count, required_role) \
                    \ VALUES (?, ?, ?, ?, ?, ?, 1, ?, 'elaborated', ?, 'armed', ?, ?, ?, ?, ?, ?, 'group_admin') \
                    \ RETURNING monitor_id"
                    ( conversation,
                      ordinal,
                      principal,
                      armingTurn.atrTurnId,
                      T.take 4000 (T.strip goal),
                      triggerKind,
                      Jsonb triggerSpec,
                      Jsonb effectCeiling,
                      cron,
                      nextFire,
                      frontier,
                      cooldown,
                      expires,
                      maxFires
                    )
                pure (Right (MonitorRef (exactlyOne "armElaboratedMonitor insert" (rows :: [Only MonitorId])) ordinal))
      _ -> error "armElaboratedMonitor: duplicate arming turn"

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

listArmedMonitors ::
  (WithConnection :> es, IOE :> es) =>
  ConversationScope ->
  Eff es [ArmedMonitor]
listArmedMonitors scope =
  query
    "SELECT m.monitor_id, m.monitor_ordinal, m.goal_text, m.trigger_kind, \
    \       m.continuation_kind, m.next_fire_at, m.expires_at, m.fire_count, \
    \       m.max_fire_count, m.created_at \
    \FROM monitors m JOIN conversations c USING (conversation_id) \
    \WHERE c.legacy_group_id=? AND m.status='armed' \
    \ORDER BY m.monitor_ordinal"
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
      \    AND NOT EXISTS (SELECT 1 FROM monitor_fires f WHERE f.monitor_id=m.monitor_id \
      \      AND f.admission_state='pending' AND f.cancelled_at IS NULL) \
      \  UNION ALL \
      \  SELECT m.expires_at FROM monitors m \
      \  WHERE m.status='armed' AND m.expires_at IS NOT NULL \
      \  UNION ALL \
      \  SELECT CASE WHEN f.claim_expires_at>? THEN f.claim_expires_at \
      \              ELSE COALESCE(f.next_attempt_at, f.created_at) END \
      \  FROM monitor_fires f JOIN monitors m USING (monitor_id) \
      \  WHERE (m.status='armed' OR (m.status='expired' AND m.status_reason='max_fire_count')) \
      \    AND f.admission_state='pending' AND f.cancelled_at IS NULL \
      \    AND f.parked_at IS NULL \
      \    AND (m.continuation_kind='canned' \
      \      OR (m.continuation_kind='elaborated' AND m.trigger_kind='time_cron' AND m.schedule_cron IS NULL) \
      \      OR (m.continuation_kind='elaborated' AND ( \
      \        SELECT count(*) FROM monitor_fires recent \
      \        JOIN monitors rm ON rm.monitor_id=recent.monitor_id \
      \        WHERE rm.conversation_id=m.conversation_id \
      \          AND rm.continuation_kind='elaborated' \
      \          AND NOT (rm.trigger_kind='time_cron' AND rm.schedule_cron IS NULL) \
      \          AND recent.admission_state='dispatched' AND recent.disposition NOT IN ('coalesced','overflow') \
      \          AND recent.dispatched_at>(?::timestamptz - interval '1 hour')) < 4)) \
      \  UNION ALL \
      \  SELECT min(recent.dispatched_at) + interval '1 hour' \
      \  FROM monitor_fires recent JOIN monitors rm USING (monitor_id) \
      \  WHERE rm.continuation_kind='elaborated' AND recent.admission_state='dispatched' AND recent.disposition NOT IN ('coalesced','overflow') \
      \    AND NOT (rm.trigger_kind='time_cron' AND rm.schedule_cron IS NULL) \
      \    AND recent.dispatched_at>(?::timestamptz - interval '1 hour') \
      \) deadlines"
      (now, now, now)
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
admitDueTimeMonitors now = withTransaction $ do
  expiredByTtl <-
    query
      "UPDATE monitors SET status='expired', status_reason='ttl_expired', next_fire_at=NULL, updated_at=now() \
      \ WHERE status='armed' AND expires_at IS NOT NULL AND expires_at<=? \
      \ RETURNING monitor_id"
      (Only now)
  missingOwners <-
    query
      "UPDATE monitors SET status='expired', status_reason='arming_principal_missing', next_fire_at=NULL, updated_at=now() \
      \ WHERE status='armed' AND continuation_kind='elaborated' AND armed_by_principal_id IS NULL \
      \ RETURNING monitor_id"
      ()
  let expiredIds =
        [monitorId | Only monitorId <- (expiredByTtl :: [Only MonitorId])]
          <> [monitorId | Only monitorId <- (missingOwners :: [Only MonitorId])]
  unless (null expiredIds) $ do
    _ <-
      execute
        "UPDATE monitor_fires SET cancelled_at=now(), claim_owner=NULL, claim_expires_at=NULL \
        \ WHERE monitor_id=ANY(?) AND admission_state='pending' AND cancelled_at IS NULL"
        (Only (PGArray expiredIds))
    pure ()
  execute
    "WITH due AS ( \
    \  SELECT m.monitor_id, m.conversation_id, m.next_fire_at FROM monitors m \
    \  WHERE m.status='armed' AND m.trigger_kind='time_cron' \
    \    AND m.next_fire_at<=? \
    \    AND NOT EXISTS (SELECT 1 FROM monitor_fires f WHERE f.monitor_id=m.monitor_id \
    \      AND f.admission_state='pending' AND f.cancelled_at IS NULL) \
    \  FOR UPDATE OF m SKIP LOCKED \
    \) INSERT INTO monitor_fires (monitor_id, conversation_id, idempotency_key, scheduled_at, trigger_evidence) \
    \SELECT due.monitor_id, due.conversation_id, \
    \       'time:' || due.monitor_id::text || ':' || extract(epoch FROM due.next_fire_at)::text, \
    \       due.next_fire_at, 'TimeCron reached ' || due.next_fire_at::text FROM due \
    \ON CONFLICT DO NOTHING"
    (Only now)

-- | Evaluate one exact canonical ingest row.  The caller invokes this only
-- for a host-authenticated LiveDelivery inbound message, from inside the same
-- transaction that inserted that row.  Candidate monitor rows are locked in
-- stable id order; cooldown advancement and the unique edge fire therefore
-- commit atomically with canonical ingest.
evaluateLedgerMatches ::
  (WithConnection :> es, IOE :> es) =>
  Int64 ->
  Int64 ->
  CanonicalMessageId ->
  PrincipalId ->
  PrincipalId ->
  Map PrincipalIdentityId PrincipalId ->
  Text ->
  Body 'Canonical ->
  UTCTime ->
  Eff es Int64
evaluateLedgerMatches conversation ingestSeq canonical sender self mentionPrincipals rendered body observedAt = do
  -- A max-count expiry still allows the already-admitted last fire to cross
  -- into its turn; TTL expiry cancels every pending occurrence quietly.
  ttlRows <-
    query
      "UPDATE monitors SET status='expired', status_reason='ttl_expired', next_fire_at=NULL, updated_at=now() \
      \ WHERE conversation_id=? AND status='armed' AND expires_at IS NOT NULL AND expires_at<=now() \
      \ RETURNING monitor_id"
      (Only conversation)
  let ttlIds = [monitorId | Only monitorId <- (ttlRows :: [Only MonitorId])]
  unless (null ttlIds) $ do
    _ <-
      execute
        "UPDATE monitor_fires SET cancelled_at=now(), claim_owner=NULL, claim_expires_at=NULL \
        \ WHERE monitor_id=ANY(?) AND admission_state='pending' AND cancelled_at IS NULL"
        (Only (PGArray ttlIds))
    pure ()
  _ <-
    execute
      "UPDATE monitors SET status='expired', status_reason='max_fire_count', next_fire_at=NULL, updated_at=now() \
      \ WHERE conversation_id=? AND status='armed' AND max_fire_count IS NOT NULL \
      \   AND fire_count>=max_fire_count"
      (Only conversation)
  candidates <-
    query
      "SELECT monitor_id, trigger_spec::text FROM monitors \
      \ WHERE conversation_id=? AND status='armed' AND trigger_kind='ledger_match' \
      \   AND continuation_kind='elaborated' AND armed_ingest_seq<? \
      \   AND (expires_at IS NULL OR expires_at>now()) \
      \   AND (max_fire_count IS NULL OR fire_count<max_fire_count) \
      \ ORDER BY monitor_id FOR UPDATE"
      (conversation, ingestSeq)
  admitted <- forM (candidates :: [(MonitorId, Text)]) $ \(monitorId, encodedSpec) ->
    case either (Left . T.pack) parseLedgerMatchSpec (eitherDecodeStrict' (TE.encodeUtf8 encodedSpec)) of
      Left err -> do
        _ <-
          execute
            "UPDATE monitors SET status='expired', status_reason=?, next_fire_at=NULL, updated_at=now() \
            \ WHERE monitor_id=? AND status='armed'"
            ("invalid_trigger_spec:" <> T.take 300 err, monitorId)
        pure 0
      Right spec
        | not (ledgerSpecMatches spec sender self mentionPrincipals rendered body) -> pure 0
        | otherwise -> do
            advanced <-
              query
                "UPDATE monitors SET cooldown_until=now() + cooldown_seconds * interval '1 second', \
                \ fire_count=fire_count+1, updated_at=now() \
                \ WHERE monitor_id=? AND status='armed' \
                \   AND (cooldown_until IS NULL OR cooldown_until<=now()) \
                \   AND (max_fire_count IS NULL OR fire_count<max_fire_count) \
                \ RETURNING fire_count, max_fire_count"
                (Only monitorId)
            case advanced :: [(Int64, Maybe Int64)] of
              [] -> pure 0
              [(newCount, maxCount)] -> do
                let CanonicalMessageId messageId = canonical
                    evidence =
                      T.take 1600 $
                        "LedgerMatch matched #"
                          <> T.pack (show messageId)
                          <> if T.null rendered then "" else ": " <> rendered
                inserted <-
                  execute
                    "INSERT INTO monitor_fires \
                    \ (monitor_id, conversation_id, idempotency_key, scheduled_at, trigger_canonical_message_id, \
                    \  trigger_evidence, counted_at_admission) \
                    \ VALUES (?, ?, 'ledger:' || ?::text || ':' || ?::text, ?, ?, ?, true) \
                    \ ON CONFLICT DO NOTHING"
                    (monitorId, conversation, monitorId, messageId, observedAt, messageId, evidence)
                when (inserted == 1 && maybe False (newCount >=) maxCount) $ do
                  _ <-
                    execute
                      "UPDATE monitors SET status='expired', status_reason='max_fire_count', \
                      \ next_fire_at=NULL, updated_at=now() WHERE monitor_id=?"
                      (Only monitorId)
                  pure ()
                pure inserted
              _ -> error "evaluateLedgerMatches: duplicate monitor update"
  pure (sum admitted)

claimCannedMonitorFires ::
  (WithConnection :> es, IOE :> es) =>
  Text ->
  UTCTime ->
  -- | How long the claim should last, in seconds; the deadline itself is the
  -- database's (issue #17.A).  A worker whose clock ran slow used to write a
  -- lease that had already expired, freeing the fire it had just taken.
  Double ->
  Int ->
  Eff es [CannedMonitorFire]
claimCannedMonitorFires owner now leaseSeconds limit =
  query
    "WITH candidates AS ( \
    \  SELECT f.fire_id FROM monitor_fires f JOIN monitors m USING (monitor_id) \
    \  WHERE m.status='armed' AND m.continuation_kind='canned' \
    \    AND f.admission_state='pending' AND f.cancelled_at IS NULL \
    \    AND f.parked_at IS NULL \
    \    AND COALESCE(f.next_attempt_at, f.created_at)<=? \
    \    AND max_lease_free(f.claim_owner, f.claim_expires_at) \
    \  ORDER BY COALESCE(f.next_attempt_at, f.created_at), f.fire_id \
    \  FOR UPDATE OF f SKIP LOCKED LIMIT ? \
    \), claimed AS ( \
    \  UPDATE monitor_fires f SET claim_owner=?, claim_expires_at=max_lease_until(?) \
    \  FROM candidates c WHERE f.fire_id=c.fire_id \
    \  RETURNING f.fire_id, f.monitor_id, f.scheduled_at, f.delivery_attempts, f.claim_owner \
    \) \
    \SELECT claimed.fire_id, m.monitor_id, m.monitor_ordinal, c.legacy_group_id, \
    \       m.armed_by_principal_id, m.goal_text, m.schedule_cron, \
    \       claimed.scheduled_at, claimed.delivery_attempts, claimed.claim_owner \
    \FROM claimed JOIN monitors m USING (monitor_id) JOIN conversations c USING (conversation_id) \
    \ORDER BY claimed.scheduled_at, claimed.fire_id"
    (now, max 1 (min 100 limit), owner, leaseSeconds)

claimElaboratedMonitorFires ::
  (WithConnection :> es, IOE :> es) =>
  Text ->
  UTCTime ->
  -- | Lease length in seconds; see 'claimCannedMonitorFires'.
  Double ->
  Int ->
  Eff es [ElaboratedMonitorFire]
claimElaboratedMonitorFires owner now leaseSeconds limit =
  query
    ( "WITH candidates AS ( \
      \  SELECT f.fire_id FROM monitor_fires f \
      \  JOIN monitors m USING (monitor_id) \
      \  WHERE m.continuation_kind='elaborated' \
      \    AND m.armed_by_principal_id IS NOT NULL \
      \    AND (m.status='armed' OR (m.status='expired' AND m.status_reason='max_fire_count')) \
      \    AND f.admission_state='pending' AND f.cancelled_at IS NULL \
      \    AND max_lease_free(f.claim_owner, f.claim_expires_at) \
      \    AND ( \
      \      (m.trigger_kind='time_cron' AND m.schedule_cron IS NULL) OR \
      \      (SELECT count(*) FROM monitor_fires recent \
      \       JOIN monitors rm ON rm.monitor_id=recent.monitor_id \
      \       WHERE rm.conversation_id=m.conversation_id \
      \         AND rm.continuation_kind='elaborated' \
      \         AND NOT (rm.trigger_kind='time_cron' AND rm.schedule_cron IS NULL) \
      \         AND recent.admission_state='dispatched' AND recent.disposition NOT IN ('coalesced','overflow') \
      \         AND recent.dispatched_at>(?::timestamptz - interval '1 hour')) < 4 \
      \    ) \
      \  ORDER BY f.created_at, f.fire_id \
      \  FOR UPDATE OF f SKIP LOCKED LIMIT ? \
      \), claimed AS ( \
      \  UPDATE monitor_fires f SET claim_owner=?, claim_expires_at=max_lease_until(?) \
      \  FROM candidates c WHERE f.fire_id=c.fire_id \
      \  RETURNING f.fire_id \
      \) "
        <> elaboratedFireSelect
        <> " JOIN claimed ON claimed.fire_id=f.fire_id ORDER BY f.created_at, f.fire_id"
    )
    (now, max 1 (min 100 limit), owner, leaseSeconds)

loadAdmittedMonitorFire ::
  (WithConnection :> es, IOE :> es) =>
  MonitorFireId ->
  Eff es (Maybe ElaboratedMonitorFire)
loadAdmittedMonitorFire fireId = do
  rows <-
    query
      (elaboratedFireSelect <> " WHERE f.fire_id=? AND f.admission_state='dispatched' AND f.admitted_turn_id IS NOT NULL")
      (Only fireId)
  pure (listToMaybe rows)

elaboratedFireSelect :: Query
elaboratedFireSelect =
  "SELECT f.fire_id, m.monitor_id, m.monitor_ordinal, c.legacy_group_id, \
  \       m.armed_by_principal_id, m.arming_turn_id, arming.turn_ordinal, \
  \       seed.canonical_message_id, COALESCE(f.definition_snapshot->>'goal',m.goal_text), m.trigger_kind, m.schedule_cron, \
  \       f.scheduled_at, f.trigger_canonical_message_id, f.trigger_evidence, \
  \       COALESCE(f.definition_snapshot->'grants'->'tool_grants',m.effect_ceiling->'tool_grants', '{}'::jsonb)::text, \
  \       COALESCE(f.definition_snapshot->>'required_role',m.required_role), f.claim_owner, f.admitted_turn_id, admitted.turn_ordinal \
  \FROM monitor_fires f \
  \JOIN monitors m USING (monitor_id) \
  \JOIN conversations c ON c.conversation_id=m.conversation_id \
  \LEFT JOIN agent_turns arming ON arming.turn_id=m.arming_turn_id \
  \LEFT JOIN agent_turns admitted ON admitted.turn_id=f.admitted_turn_id \
  \LEFT JOIN LATERAL ( \
  \  SELECT source.canonical_message_id FROM messages source \
  \  WHERE source.conversation_id=m.conversation_id \
  \    AND source.author_principal_id=m.armed_by_principal_id \
  \    AND source.message_origin='inbound' \
  \    AND source.ingest_class='live_delivery' \
  \    AND source.ingest_seq<=m.armed_ingest_seq \
  \  ORDER BY source.ingest_seq DESC LIMIT 1 \
  \) seed ON true"

-- | Fire-time admission boundary for an elaborated continuation.  The fresh
-- horizon-1 turn, fire link, fork-from provenance and TimeCron advancement
-- commit together.  After this transaction, restart recovery owns the turn;
-- the scheduler must never create a replacement.
admitElaboratedMonitorTurn ::
  (WithConnection :> es, IOE :> es) =>
  Text ->
  MonitorFireId ->
  Maybe UTCTime ->
  Eff es (Maybe AgentTurnRef)
admitElaboratedMonitorTurn owner fireId nextFire = withTransaction $ do
  rows <-
    query
      "SELECT m.monitor_id, m.conversation_id, m.armed_by_principal_id, m.arming_turn_id, \
      \       m.trigger_kind, m.schedule_cron, f.trigger_canonical_message_id, f.counted_at_admission \
      \FROM monitor_fires f JOIN monitors m USING (monitor_id) \
      \JOIN conversations c ON c.conversation_id=m.conversation_id \
      \WHERE f.fire_id=? AND f.admission_state='pending' AND f.cancelled_at IS NULL \
      \  AND f.claim_owner=? \
      \  AND (m.status='armed' OR (m.status='expired' AND m.status_reason='max_fire_count')) \
      \FOR UPDATE OF c, m, f"
      (fireId, owner)
  case rows :: [(MonitorId, Int64, Maybe Int64, Maybe AgentTurnId, Text, Maybe Text, Maybe Int64, Bool)] of
    [] -> pure Nothing
    [(monitorId, conversation, maybePrincipal, armingTurn, triggerKind, scheduleCron, triggerCanonical, counted)] ->
      case maybePrincipal of
        Nothing -> pure Nothing
        Just principal -> do
          recentRows <-
            query
              "SELECT count(*) FROM monitor_fires recent \
              \ JOIN monitors rm USING (monitor_id) \
              \ WHERE rm.conversation_id=? AND rm.continuation_kind='elaborated' \
              \   AND NOT (rm.trigger_kind='time_cron' AND rm.schedule_cron IS NULL) \
              \   AND recent.admission_state='dispatched' AND recent.disposition NOT IN ('coalesced','overflow') \
              \   AND recent.dispatched_at>now() - interval '1 hour'"
              (Only conversation)
          let recentCount = exactlyOne "admitElaboratedMonitorTurn budget" (recentRows :: [Only Int64])
              bypassBudget = triggerKind == "time_cron" && isNothing scheduleCron
          if not bypassBudget && recentCount >= 4
            then do
              _ <-
                execute
                  "UPDATE monitor_fires SET claim_owner=NULL, claim_expires_at=NULL \
                  \ WHERE fire_id=? AND admission_state='pending' AND claim_owner=?"
                  (fireId, owner)
              pure Nothing
            else do
              ordinalRows <-
                query
                  "SELECT COALESCE(max(turn_ordinal),0)+1 FROM agent_turns WHERE conversation_id=?"
                  (Only conversation)
              let ordinal = exactlyOne "admitElaboratedMonitorTurn ordinal" (ordinalRows :: [Only TurnOrdinal])
              turnRows <-
                query
                  "INSERT INTO agent_turns \
                  \ (conversation_id, turn_ordinal, trigger_canonical_message_id, initiator_principal_id, status) \
                  \ VALUES (?, ?, ?, ?, 'starting') RETURNING turn_id"
                  (conversation, ordinal, triggerCanonical, principal)
              let turnId = exactlyOne "admitElaboratedMonitorTurn turn" (turnRows :: [Only AgentTurnId])
                  turn = AgentTurnRef turnId ordinal
              changed <-
                execute
                  "UPDATE monitor_fires SET admission_state='dispatched', admitted_turn_id=?, dispatched_at=now(), \
                  \ claim_owner=NULL, claim_expires_at=NULL, next_attempt_at=NULL, last_error=NULL, parked_at=NULL \
                  \ WHERE fire_id=? AND admission_state='pending' AND claim_owner=?"
                  (turnId, fireId, owner)
              if changed /= 1
                then error "admitElaboratedMonitorTurn: lost claimed fire"
                else do
                  forM_ armingTurn $ \sourceTurn ->
                    execute
                      "INSERT INTO turn_edges (conversation_id, from_turn_id, to_turn_id, edge_kind, created_by) \
                      \VALUES (?, ?, ?, 'fork-from', ?) ON CONFLICT DO NOTHING"
                      (conversation, turnId, sourceTurn, principal)
                  when (triggerKind == "time_cron") $ do
                    _ <-
                      execute
                        "UPDATE monitors SET \
                        \ status=CASE WHEN ?::timestamptz IS NULL THEN 'fired' ELSE 'armed' END, \
                        \ status_reason=NULL, next_fire_at=?, \
                        \ fire_count=fire_count + CASE WHEN ?::boolean THEN 0 ELSE 1 END, updated_at=now() \
                        \ WHERE monitor_id=?"
                        (nextFire, nextFire, counted, monitorId)
                    pure ()
                  pure (Just turn)
    _ -> error "admitElaboratedMonitorTurn: duplicate fire"

expireElaboratedMonitorFire ::
  (WithConnection :> es, IOE :> es) =>
  Text ->
  MonitorFireId ->
  Text ->
  Eff es Bool
expireElaboratedMonitorFire owner fireId reason = withTransaction $ do
  rows <-
    query
      "SELECT m.monitor_id FROM monitor_fires f JOIN monitors m USING (monitor_id) \
      \ WHERE f.fire_id=? AND f.admission_state='pending' AND f.cancelled_at IS NULL \
      \   AND f.claim_owner=? FOR UPDATE OF m, f"
      (fireId, owner)
  case rows :: [Only MonitorId] of
    [] -> pure False
    [Only monitorId] -> do
      _ <-
        execute
          "UPDATE monitors SET status='expired', status_reason=?, next_fire_at=NULL, updated_at=now() \
          \ WHERE monitor_id=? AND status IN ('armed','expired')"
          (T.take 500 reason, monitorId)
      _ <-
        execute
          "UPDATE monitor_fires SET cancelled_at=now(), claim_owner=NULL, claim_expires_at=NULL \
          \ WHERE monitor_id=? AND admission_state='pending' AND cancelled_at IS NULL"
          (Only monitorId)
      pure True
    _ -> error "expireElaboratedMonitorFire: duplicate fire"

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
--
-- On the server's clock, like every other reader of these two columns (issue
-- #17.A).  It used to take the booting process's @now@, which is the one clock
-- with no relationship to the one the claims were written against — a node
-- starting up with a fast clock would take back leases that had not run out.
--
-- Deliberately /not/ 'max_lease_free', despite testing the same columns: that
-- predicate counts a row nobody holds as free, and this statement's return
-- value is a count of claims actually taken away from somebody, which is what
-- makes it worth logging at boot.
reclaimExpiredMonitorFireClaims ::
  (WithConnection :> es, IOE :> es) =>
  Eff es Int64
reclaimExpiredMonitorFireClaims =
  execute
    "UPDATE monitor_fires SET claim_owner=NULL, claim_expires_at=NULL \
    \ WHERE admission_state='pending' \
    \   AND claim_owner IS NOT NULL AND claim_expires_at <= now()"
    ()

exactlyOne :: Text -> [Only a] -> a
exactlyOne _ [Only value] = value
exactlyOne label _ = error (show label <> ": expected exactly one row")
