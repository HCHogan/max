-- | Explicit occurrence insertion replaces both monitor and browser snapshot
-- triggers. Caller owns the pinned transaction and conversation lock.
module Max.DB.Monitor.Occurrence
  ( MonitorDefinition (..),
    OccurrenceDraft (..),
    loadDefinition,
    recordOccurrence,
    insertOccurrenceWithin,
    PreparedOccurrence,
    occurrenceRoute,
    prepareOccurrenceWithin,
    insertPreparedOccurrenceWithin,
  )
where

import Data.Aeson (Value (String))
import Data.ByteString qualified as BS
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime)
import Database.PostgreSQL.Simple.FromRow (FromRow (..), field)
import Database.PostgreSQL.Simple.Types (Only (..))
import Effectful
import Effectful.PostgreSQL (WithConnection, query)
import Max.DB.Codec (databaseNow, enumField, jsonField, jsonText)
import Max.DB.Transaction (withTransaction)
import Max.Monitor.Policy
import Max.Monitor.Types (MonitorFireId, MonitorId (..))
import Max.Node.Routing
import Max.Task.Types (parseProfile)
import Max.Turn.Types (AgentTurnId)

data MonitorDefinition = MonitorDefinition
  { monitorId :: !MonitorId,
    conversation :: !Int64,
    revision :: !Int,
    snapshot :: !DefinitionSnapshot,
    elaborated :: !Bool,
    timed :: !Bool,
    recurring :: !Bool,
    owner :: !(Maybe Int64),
    armingTurn :: !(Maybe AgentTurnId),
    active :: !Bool,
    expires :: !(Maybe UTCTime)
  }
  deriving stock (Show, Eq)

instance FromRow MonitorDefinition where
  fromRow =
    MonitorDefinition
      <$> field
      <*> field
      <*> field
      <*> (DefinitionSnapshot <$> field <*> jsonField <*> field <*> enumField parseProfile <*> field <*> enumField parseOverlapPolicy <*> field <*> field <*> field)
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field

loadDefinition :: (WithConnection :> es, IOE :> es) => MonitorId -> Eff es (Maybe MonitorDefinition)
loadDefinition identifier = do
  rows <-
    query
      "SELECT m.monitor_id,m.conversation_id,m.definition_revision,m.goal_text,COALESCE(m.effect_ceiling->'tool_grants','{}'::jsonb)::text,\
      \ m.required_role,m.task_profile,m.change_only,m.overlap_policy,m.queue_limit,b.profile_id,b.profile_version,\
      \ m.continuation_kind='elaborated',m.trigger_kind='time_cron',m.schedule_cron IS NOT NULL,m.armed_by_principal_id,m.arming_turn_id,\
      \ COALESCE((m.status='armed' OR m.status='expired' AND m.status_reason='max_fire_count'),false),m.expires_at\
      \ FROM monitors m LEFT JOIN browser_monitor_profiles b USING(monitor_id) WHERE m.monitor_id=? FOR UPDATE OF m"
      (Only identifier)
  pure $ case rows of [row] -> Just row; _ -> Nothing

data OccurrenceDraft = OccurrenceDraft
  { key :: !Text,
    scheduled :: !UTCTime,
    sourceMessage :: !(Maybe Int64),
    evidence :: !Text,
    payload :: !(Maybe Value),
    counted :: !Bool
  }
  deriving stock (Eq, Show)

-- | The plan is consumed under the same conversation/definition locks that
-- supplied its buffer facts. Ingress can inspect it without recalculating policy.
data PreparedOccurrence = PreparedOccurrence !MonitorDefinition !OccurrenceDraft !OccurrenceRoute

occurrenceRoute :: PreparedOccurrence -> OccurrenceRoute
occurrenceRoute (PreparedOccurrence _ _ route) = route

prepareOccurrenceWithin :: (WithConnection :> es, IOE :> es) => MonitorDefinition -> OccurrenceDraft -> Eff es PreparedOccurrence
prepareOccurrenceWithin definition draft = do
  -- Discarded timer markers still need schedule acknowledgement, but they do
  -- not consume buffer capacity or become a coalescing destination.
  rows <-
    query
      "SELECT (count(*) OVER ())::integer,f.fire_id,f.admission_state='pending',\
      \ (SELECT count(*)::integer FROM monitor_fires WHERE coalesced_into=f.fire_id),\
      \ (octet_length(to_jsonb(f.trigger_evidence)::text)+COALESCE(octet_length(f.trigger_payload::text),0)+\
      \  (SELECT COALESCE(sum(octet_length(to_jsonb(trigger_evidence)::text)+COALESCE(octet_length(trigger_payload::text),0)),0) FROM monitor_fires WHERE coalesced_into=f.fire_id))::bigint\
      \ FROM monitor_fires f WHERE f.monitor_id=? AND f.definition_revision=? AND f.cancelled_at IS NULL\
      \ AND ((f.admission_state='pending' AND f.disposition='pending') OR (f.task_id IS NOT NULL AND f.started_at IS NULL AND f.finished_at IS NULL))\
      \ ORDER BY f.fire_id LIMIT 1"
      (definition.monitorId, definition.revision)
  let buffer = case rows of
        [(count, fire, mutable, messages, bytes)] -> OccurrenceBuffer count (Just (MergeCandidate fire mutable messages bytes))
        _ -> OccurrenceBuffer 0 Nothing
      size text = fromIntegral (BS.length (TE.encodeUtf8 text))
      incomingBytes = size (jsonText (String draft.evidence)) + maybe 0 (size . jsonText) draft.payload
      route = if definition.elaborated then routeOccurrence definition.snapshot.overlap definition.snapshot.capacity incomingBytes buffer else BufferOccurrence
  pure (PreparedOccurrence definition draft route)

insertOccurrenceWithin :: (WithConnection :> es, IOE :> es) => MonitorDefinition -> OccurrenceDraft -> Eff es (Maybe MonitorFireId)
insertOccurrenceWithin definition draft = prepareOccurrenceWithin definition draft >>= insertPreparedOccurrenceWithin

insertPreparedOccurrenceWithin :: (WithConnection :> es, IOE :> es) => PreparedOccurrence -> Eff es (Maybe MonitorFireId)
insertPreparedOccurrenceWithin (PreparedOccurrence definition draft route) = do
  let (disposition, coalesced, failure) = case route of
        BufferOccurrence -> (PendingOccurrence, Nothing, Nothing)
        MergeInto target -> (CoalescedOccurrence, Just target, Nothing)
        RecordOverflow reason -> (OverflowOccurrence, Nothing, Just (overflowReason reason))
      discarded = disposition == CoalescedOccurrence || disposition == OverflowOccurrence
  now <- databaseNow
  inserted <-
    query
      "INSERT INTO monitor_fires(monitor_id,conversation_id,idempotency_key,scheduled_at,trigger_canonical_message_id,\
      \ trigger_evidence,trigger_payload,counted_at_admission,definition_revision,definition_snapshot,disposition,coalesced_into,cancelled_at,last_error)\
      \ VALUES(?,?,?,?,?,?,?::jsonb,?,?,?::jsonb,?,?,?,?) ON CONFLICT DO NOTHING RETURNING fire_id"
      ( definition.monitorId,
        definition.conversation,
        draft.key,
        draft.scheduled,
        draft.sourceMessage,
        draft.evidence,
        fmap jsonText draft.payload,
        draft.counted,
        definition.revision,
        jsonText definition.snapshot,
        dispositionText disposition,
        coalesced,
        if discarded && not definition.timed then Just now else Nothing,
        failure
      )
  pure $ case inserted of [Only fire] -> Just fire; _ -> Nothing

-- | Host entry for a single occurrence. Batched ingest/scheduling callers use
-- insertOccurrenceWithin inside their already-pinned transaction instead.
recordOccurrence :: (WithConnection :> es, IOE :> es) => MonitorId -> OccurrenceDraft -> Eff es (Maybe MonitorFireId)
recordOccurrence monitor draft = withTransaction $ do
  (_ :: [Only Int64]) <- query "SELECT c.conversation_id FROM conversations c JOIN monitors m USING(conversation_id) WHERE m.monitor_id=? FOR UPDATE OF c" (Only monitor)
  definition <- loadDefinition monitor
  maybe (pure Nothing) (`insertOccurrenceWithin` draft) definition
