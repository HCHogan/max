-- | Monitor definitions and trigger facts. One scheduler dispatches each
-- occurrence; startup interrupts unfinished occurrences instead of replaying them.
module Max.DB.Monitor
  ( TimeMonitor (..),
    CannedMonitorFire (..),
    ElaboratedMonitorFire (..),
    ArmedMonitor (..),
    MonitorArmError (..),
    armCannedTimeMonitor,
    armElaboratedTimeMonitor,
    armLedgerMatchMonitor,
    armElaboratedMonitor,
    listCannedTimeMonitors,
    listArmedMonitors,
    nextMonitorDeadline,
    admitDueTimeMonitors,
    evaluateLedgerMatches,
    pendingCannedMonitorFires,
    pendingElaboratedMonitorFires,
    expireElaboratedMonitorFire,
    lookupMonitorFireOutput,
    beginCannedMonitorFire,
    finishCannedMonitorFire,
    interruptMonitorFires,
  )
where

import Control.Monad (forM, forM_, unless, void, when)
import Data.Aeson (Value, eitherDecodeStrict', object, (.=))
import Data.Either (fromRight)
import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (listToMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (TimeZone, UTCTime)
import Database.PostgreSQL.Simple (Only (..), Query)
import Database.PostgreSQL.Simple.FromRow (FromRow (..), RowParser, field)
import Database.PostgreSQL.Simple.ToField (ToField (..), toJSONField)
import Database.PostgreSQL.Simple.Types (PGArray (..))
import Effectful
import Effectful.PostgreSQL (WithConnection, execute, query)
import Max.ConversationScope (ConversationScope, conversationStorageId)
import Max.DB.Codec (queryRows)
import Max.DB.Monitor.Occurrence qualified as Occurrence
import Max.DB.Transaction (withTransaction)
import Max.IR (Body, Phase (Canonical))
import Max.Monitor.Control (MonitorArmError (..))
import Max.Monitor.Schedule (nextCronFire)
import Max.Monitor.Types
import Max.Monitor.View (ArmedMonitor (..), TimeMonitor (..))
import Max.Platform.Types (CanonicalMessageId (..), PrincipalId (..), PrincipalIdentityId)
import Max.Turn.Types (AgentTurnRef (..))
import OneBot.Types (GroupId (..))
import System.Cron.Parser (parseCronSchedule)

newtype Jsonb = Jsonb Value

instance ToField Jsonb where
  toField (Jsonb value) = toJSONField value

armedMonitorRow :: RowParser ArmedMonitor
armedMonitorRow =
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
    emfRequiredRole :: !Text
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
          emfRequiredRole = requiredRole
        }

timeMonitorRow :: RowParser TimeMonitor
timeMonitorRow = do
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
        tmFireCount = fireCount
      }

data CannedMonitorFire = CannedMonitorFire
  { cmfFireId :: !MonitorFireId,
    cmfMonitor :: !MonitorRef,
    cmfGroupId :: !Int64,
    cmfAuthorPrincipalId :: !(Maybe Int64),
    cmfText :: !Text,
    cmfCron :: !(Maybe Text),
    cmfScheduledAt :: !UTCTime
  }
  deriving stock (Show, Eq)

instance FromRow CannedMonitorFire where
  fromRow = do
    fire <- field
    monitor <- MonitorRef <$> field <*> field
    group <- field
    author <- field
    body <- field
    cron <- field
    scheduled <- field
    pure CannedMonitorFire {cmfFireId = fire, cmfMonitor = monitor, cmfGroupId = group, cmfAuthorPrincipalId = author, cmfText = body, cmfCron = cron, cmfScheduledAt = scheduled}

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
        \ VALUES (?, ?, ?, ?, ?, 'time_cron', 1, ?, \
        \   'canned', '{}'::jsonb, 'armed', ?, ?) \
        \ RETURNING monitor_id"
        ( conversation,
          ordinal,
          principal,
          fmap (.atrTurnId) armingTurn,
          body,
          Jsonb (object (["kind" .= ("TimeCron" :: Text), "version" .= (1 :: Int), "at" .= fireAt] <> ["cron" .= expression | Just expression <- [cron]])),
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
        if armedCount >= 100
          then pure (Left ArmedMonitorCapReached)
          else
            if triggerKind /= "time_cron" && conditionCount >= 25
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
  queryRows
    timeMonitorRow
    "SELECT m.monitor_id, m.monitor_ordinal, c.legacy_group_id, m.armed_by_principal_id, \
    \       m.arming_turn_id, arming.turn_ordinal, m.goal_text, m.schedule_cron, \
    \       m.next_fire_at, m.created_at, m.fire_count \
    \FROM conversations c JOIN monitors m USING (conversation_id) \
    \LEFT JOIN agent_turns arming ON arming.turn_id=m.arming_turn_id AND arming.conversation_id=m.conversation_id \
    \WHERE c.legacy_group_id=? AND m.status='armed' AND m.trigger_kind='time_cron' \
    \  AND m.continuation_kind='canned' \
    \ORDER BY m.next_fire_at, m.monitor_ordinal"
    (Only (conversationStorageId scope))

listArmedMonitors ::
  (WithConnection :> es, IOE :> es) =>
  ConversationScope ->
  Eff es [ArmedMonitor]
listArmedMonitors scope =
  queryRows
    armedMonitorRow
    "SELECT m.monitor_id, m.monitor_ordinal, m.goal_text, m.trigger_kind, \
    \       m.continuation_kind, m.next_fire_at, m.expires_at, m.fire_count, \
    \       m.max_fire_count, m.created_at \
    \FROM monitors m JOIN conversations c USING (conversation_id) \
    \WHERE c.legacy_group_id=? AND m.status='armed' \
    \ORDER BY m.monitor_ordinal"
    (Only (conversationStorageId scope))

-- | Wake for a calendar deadline, expiry, or the hourly budget opening.
nextMonitorDeadline ::
  (WithConnection :> es, IOE :> es) =>
  UTCTime ->
  [MonitorFireId] ->
  Eff es (Maybe UTCTime)
nextMonitorDeadline now deferred = do
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
      \  SELECT f.created_at \
      \  FROM monitor_fires f JOIN monitors m USING (monitor_id) \
      \  WHERE (m.status='armed' OR (m.status='expired' AND m.status_reason='max_fire_count')) \
      \    AND f.admission_state='pending' AND f.cancelled_at IS NULL \
      \    AND NOT (f.fire_id=ANY(?::bigint[])) AND (m.continuation_kind='canned' \
      \      OR (m.continuation_kind='elaborated' AND m.trigger_kind='time_cron' AND m.schedule_cron IS NULL) \
      \      OR (m.continuation_kind='elaborated' AND ( \
      \        SELECT count(*) FROM monitor_fires recent \
      \        JOIN monitors rm ON rm.monitor_id=recent.monitor_id \
      \        WHERE rm.conversation_id=m.conversation_id \
      \          AND rm.continuation_kind='elaborated' \
      \          AND NOT (rm.trigger_kind='time_cron' AND rm.schedule_cron IS NULL) \
      \          AND recent.admission_state='dispatched' AND recent.disposition NOT IN ('coalesced','overflow') \
      \          AND recent.dispatched_at>(?::timestamptz - interval '1 hour')) < 20)) \
      \  UNION ALL \
      \  SELECT min(recent.dispatched_at) + interval '1 hour' \
      \  FROM monitor_fires recent JOIN monitors rm USING (monitor_id) \
      \  WHERE rm.continuation_kind='elaborated' AND recent.admission_state='dispatched' AND recent.disposition NOT IN ('coalesced','overflow') \
      \    AND NOT (rm.trigger_kind='time_cron' AND rm.schedule_cron IS NULL) \
      \    AND recent.dispatched_at>(?::timestamptz - interval '1 hour') \
      \) deadlines"
      (PGArray deferred, now, now)
  pure $ case rows :: [Only (Maybe UTCTime)] of
    [Only deadline] -> deadline
    _ -> Nothing

-- | Record each due calendar edge once. Startup retires any unfinished edge.
admitDueTimeMonitors ::
  (WithConnection :> es, IOE :> es) =>
  UTCTime ->
  Eff es Int64
admitDueTimeMonitors now = withTransaction $ do
  locked <-
    query
      "SELECT c.conversation_id FROM conversations c WHERE EXISTS(SELECT 1 FROM monitors m WHERE m.conversation_id=c.conversation_id AND m.status='armed'\
      \ AND (m.expires_at<=? OR m.continuation_kind='elaborated' AND m.armed_by_principal_id IS NULL OR m.trigger_kind='time_cron' AND m.next_fire_at<=?))\
      \ ORDER BY c.conversation_id FOR UPDATE OF c SKIP LOCKED"
      (now, now)
  let conversations = PGArray [identifier | Only identifier <- (locked :: [Only Int64])]

  expiredByTtl <-
    query
      "UPDATE monitors SET status='expired', status_reason='ttl_expired', next_fire_at=NULL, updated_at=now() \
      \ WHERE conversation_id=ANY(?) AND status='armed' AND expires_at IS NOT NULL AND expires_at<=? \
      \ RETURNING monitor_id"
      (conversations, now)
  missingOwners <-
    query
      "UPDATE monitors SET status='expired', status_reason='arming_principal_missing', next_fire_at=NULL, updated_at=now() \
      \ WHERE conversation_id=ANY(?) AND status='armed' AND continuation_kind='elaborated' AND armed_by_principal_id IS NULL \
      \ RETURNING monitor_id"
      (Only conversations)
  let expiredIds =
        [monitorId | Only monitorId <- (expiredByTtl :: [Only MonitorId])]
          <> [monitorId | Only monitorId <- (missingOwners :: [Only MonitorId])]
  unless (null expiredIds) $ do
    _ <-
      execute
        "UPDATE monitor_fires SET cancelled_at=now() \
        \ WHERE monitor_id=ANY(?) AND admission_state='pending' AND cancelled_at IS NULL"
        (Only (PGArray expiredIds))
    pure ()
  due <-
    query
      "SELECT m.monitor_id,m.next_fire_at FROM monitors m WHERE m.conversation_id=ANY(?) AND m.status='armed' AND m.trigger_kind='time_cron'\
      \ AND m.next_fire_at<=? AND NOT EXISTS(SELECT 1 FROM monitor_fires f WHERE f.monitor_id=m.monitor_id AND f.admission_state='pending' AND f.cancelled_at IS NULL)\
      \ ORDER BY m.monitor_id FOR UPDATE OF m SKIP LOCKED"
      (conversations, now)
  inserted <- forM (due :: [(MonitorId, UTCTime)]) $ \(identifier, scheduled) -> do
    definition <- Occurrence.loadDefinition identifier
    case definition of
      Nothing -> pure 0
      Just current -> do
        let draft =
              Occurrence.OccurrenceDraft
                ("time:" <> T.pack (show identifier.unMonitorId) <> ":" <> T.pack (show scheduled))
                scheduled
                Nothing
                ("TimeCron reached " <> T.pack (show scheduled))
                Nothing
                False
        occurrence <- Occurrence.insertOccurrenceWithin current draft
        pure $ maybe 0 (const 1) occurrence
  pure (sum inserted)

-- | Evaluate one exact canonical ingest row.  The caller invokes this only
-- for a host-authenticated LiveDelivery inbound message, from inside the same
-- transaction that inserted that row.  Candidate monitor rows are locked in
-- stable id order; the caller already owns the conversation lock. Cooldown
-- advancement and the unique edge fire therefore
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
        "UPDATE monitor_fires SET cancelled_at=now() \
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
                definition <- Occurrence.loadDefinition monitorId
                occurrence <- case definition of
                  Nothing -> pure Nothing
                  Just current ->
                    Occurrence.insertOccurrenceWithin
                      current
                      (Occurrence.OccurrenceDraft ("ledger:" <> T.pack (show monitorId.unMonitorId) <> ":" <> T.pack (show messageId)) observedAt (Just messageId) evidence Nothing True)
                let inserted = maybe 0 (const 1) occurrence
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

-- The application runs exactly one monitor scheduler. These are trigger
-- markers, not worker claims; dispatch never transfers to another process.
pendingCannedMonitorFires :: (WithConnection :> es, IOE :> es) => Int -> Eff es [CannedMonitorFire]
pendingCannedMonitorFires limit =
  query
    "SELECT f.fire_id,m.monitor_id,m.monitor_ordinal,c.legacy_group_id,m.armed_by_principal_id,f.definition_snapshot->>'goal',m.schedule_cron,f.scheduled_at\
    \ FROM monitor_fires f JOIN monitors m USING(monitor_id) JOIN conversations c ON c.conversation_id=m.conversation_id\
    \ WHERE m.status='armed' AND m.continuation_kind='canned' AND f.admission_state='pending' AND f.cancelled_at IS NULL\
    \ ORDER BY f.fire_id LIMIT ?"
    (Only (max 1 (min 100 limit)))

pendingElaboratedMonitorFires :: (WithConnection :> es, IOE :> es) => UTCTime -> [MonitorFireId] -> MonitorFireId -> Int -> Eff es [ElaboratedMonitorFire]
pendingElaboratedMonitorFires now deferred after limit =
  query
    ( elaboratedFireSelect
        <> " WHERE NOT (f.fire_id=ANY(?::bigint[])) AND m.continuation_kind='elaborated' AND m.armed_by_principal_id IS NOT NULL\
           \ AND (m.status='armed' OR (m.status='expired' AND m.status_reason='max_fire_count'))\
           \ AND f.admission_state='pending' AND f.cancelled_at IS NULL\
           \ AND ((m.trigger_kind='time_cron' AND m.schedule_cron IS NULL) OR\
           \ (SELECT count(*) FROM monitor_fires recent JOIN monitors rm USING(monitor_id)\
           \ WHERE rm.conversation_id=m.conversation_id AND rm.continuation_kind='elaborated'\
           \ AND NOT (rm.trigger_kind='time_cron' AND rm.schedule_cron IS NULL)\
           \ AND recent.admission_state='dispatched' AND recent.disposition NOT IN ('coalesced','overflow')\
           \ AND recent.dispatched_at>(?::timestamptz - interval '1 hour'))<20)\
           \ ORDER BY (f.fire_id<=?),f.fire_id LIMIT ?"
    )
    (PGArray deferred, now, after, max 1 (min 100 limit))

elaboratedFireSelect :: Query
elaboratedFireSelect =
  "SELECT f.fire_id, m.monitor_id, m.monitor_ordinal, c.legacy_group_id, \
  \       m.armed_by_principal_id, m.arming_turn_id, arming.turn_ordinal, \
  \       seed.canonical_message_id, COALESCE(f.definition_snapshot->>'goal',m.goal_text), m.trigger_kind, m.schedule_cron, \
  \       f.scheduled_at, f.trigger_canonical_message_id, f.trigger_evidence, \
  \       COALESCE(f.definition_snapshot->'grants'->'tool_grants',m.effect_ceiling->'tool_grants', '{}'::jsonb)::text, \
  \       COALESCE(f.definition_snapshot->>'required_role',m.required_role) \
  \FROM monitor_fires f \
  \JOIN monitors m USING (monitor_id) \
  \JOIN conversations c ON c.conversation_id=m.conversation_id \
  \LEFT JOIN agent_turns arming ON arming.turn_id=m.arming_turn_id \
  \LEFT JOIN LATERAL ( \
  \  SELECT source.canonical_message_id FROM messages source \
  \  WHERE source.conversation_id=m.conversation_id \
  \    AND source.author_principal_id=m.armed_by_principal_id \
  \    AND source.message_origin='inbound' \
  \    AND source.ingest_class='live_delivery' \
  \    AND source.ingest_seq<=m.armed_ingest_seq \
  \  ORDER BY source.ingest_seq DESC LIMIT 1 \
  \) seed ON true"

expireElaboratedMonitorFire ::
  (WithConnection :> es, IOE :> es) =>
  MonitorFireId ->
  Text ->
  Eff es Bool
expireElaboratedMonitorFire fireId reason = withTransaction $ do
  rows <-
    query
      "SELECT m.monitor_id FROM monitor_fires f JOIN monitors m USING (monitor_id) \
      \ WHERE f.fire_id=? AND f.admission_state='pending' AND f.cancelled_at IS NULL \
      \   FOR UPDATE OF m, f"
      (Only fireId)
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
          "UPDATE monitor_fires SET cancelled_at=now() \
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

-- | Consume the calendar edge before publication. A crash can lose this
-- occurrence, but cannot repeat its external effect on restart.
beginCannedMonitorFire :: (WithConnection :> es, IOE :> es) => MonitorFireId -> Maybe UTCTime -> Eff es Bool
beginCannedMonitorFire fire next = withTransaction $ do
  rows <-
    query
      "SELECT m.monitor_id FROM monitor_fires f JOIN monitors m USING(monitor_id) WHERE f.fire_id=?\
      \ AND f.admission_state='pending' AND f.cancelled_at IS NULL AND m.status='armed' FOR UPDATE OF m,f"
      (Only fire)
  case rows :: [Only MonitorId] of
    [Only monitor] -> do
      void $ execute "UPDATE monitor_fires SET admission_state='dispatched',dispatched_at=now(),started_at=now() WHERE fire_id=?" (Only fire)
      void $ execute "UPDATE monitors SET next_fire_at=?,status=CASE WHEN ?::timestamptz IS NULL THEN 'fired' ELSE 'armed' END,fire_count=fire_count+1,updated_at=now() WHERE monitor_id=?" (next, next, monitor)
      pure True
    _ -> pure False

-- | Publication is already final; this write only records its outcome.
finishCannedMonitorFire :: (WithConnection :> es, IOE :> es) => MonitorFireId -> Either Text CanonicalMessageId -> Eff es ()
finishCannedMonitorFire fire outcome =
  void $
    execute
      "UPDATE monitor_fires SET outbound_canonical_message_id=?,last_error=?,finished_at=now() WHERE fire_id=?"
      (either (const Nothing) (Just . (.unCanonicalMessageId)) outcome, either Just (const Nothing) outcome, fire)

-- | Run once before ingress starts. Definitions survive; unfinished triggers
-- end here, including any canonical output whose acknowledgement was lost.
-- Old canned history has no started_at; some migrated rows also lack receipts.
-- Only the new publisher sets started_at before an external send.
interruptMonitorFires :: (WithConnection :> es, IOE :> es) => TimeZone -> UTCTime -> Eff es Int64
interruptMonitorFires tz now = withTransaction $ do
  schedules <-
    query
      "SELECT m.monitor_id,m.schedule_cron FROM monitors m WHERE m.status='armed' AND m.trigger_kind='time_cron'\
      \ AND EXISTS(SELECT 1 FROM monitor_fires f WHERE f.monitor_id=m.monitor_id AND f.admission_state='pending' AND f.cancelled_at IS NULL)"
      ()
  forM_ (schedules :: [(MonitorId, Maybe Text)]) $ \(monitor, cron) -> do
    let next = cron >>= either (const Nothing) (\schedule -> nextCronFire tz schedule now) . parseCronSchedule
    void $ execute "UPDATE monitors SET next_fire_at=?,status=CASE WHEN ?::timestamptz IS NULL THEN 'fired' ELSE 'armed' END,updated_at=now() WHERE monitor_id=?" (next, next, monitor)
  execute
    "UPDATE monitor_fires f SET cancelled_at=COALESCE(cancelled_at,now()),finished_at=now(),\
    \ disposition=CASE WHEN admission_state='pending' THEN 'cancelled' ELSE disposition END,\
    \ last_error=COALESCE(last_error,'process restarted before completion'),\
    \ result=COALESCE(result,jsonb_build_object('status','cancelled','summary','process restarted before completion'))\
    \ WHERE finished_at IS NULL AND cancelled_at IS NULL AND (admission_state='pending' OR task_id IS NOT NULL\
    \ OR (outbound_canonical_message_id IS NULL AND started_at IS NOT NULL\
    \ AND EXISTS(SELECT 1 FROM monitors m WHERE m.monitor_id=f.monitor_id AND m.continuation_kind='canned')))"
    ()

exactlyOne :: Text -> [Only a] -> a
exactlyOne _ [Only value] = value
exactlyOne label _ = error (show label <> ": expected exactly one row")
