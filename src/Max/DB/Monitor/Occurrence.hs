-- | Explicit occurrence insertion replaces both monitor and browser snapshot
-- triggers. Caller owns the pinned transaction and conversation lock.
module Max.DB.Monitor.Occurrence
  ( MonitorDefinition (..),
    OccurrenceDraft (..),
    loadDefinition,
    recordOccurrence,
    insertOccurrenceWithin,
  )
where

import Data.Int (Int64)
import Data.Text (Text)
import Data.Time (UTCTime)
import Database.PostgreSQL.Simple.FromRow (FromRow (..), field)
import Database.PostgreSQL.Simple.Types (Only (..))
import Effectful
import Effectful.PostgreSQL (WithConnection, query)
import Max.DB.Codec (enumField, jsonField)
import Max.DB.Task.Record (databaseNow, jsonText)
import Max.DB.Transaction (withTransaction)
import Max.Monitor.Policy
import Max.Monitor.Types (MonitorFireId, MonitorId (..))
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
    counted :: !Bool
  }
  deriving stock (Eq, Show)

insertOccurrenceWithin :: (WithConnection :> es, IOE :> es) => MonitorDefinition -> OccurrenceDraft -> Eff es (Maybe MonitorFireId)
insertOccurrenceWithin definition draft = do
  -- The locked definition pins its revision and browser binding. Query only
  -- queued work in that revision; completed history does not consume capacity.
  queued <-
    query
      "SELECT count(*)::integer,min(fire_id) FROM monitor_fires fire LEFT JOIN durable_tasks work ON work.task_id=fire.task_id\
      \ WHERE fire.monitor_id=? AND fire.cancelled_at IS NULL AND fire.definition_revision=?\
      \ AND (fire.admission_state='pending' OR work.status='queued')"
      (definition.monitorId, definition.revision)
  let (count, pending) = case queued :: [(Int, Maybe Int64)] of [row] -> row; _ -> (0, Nothing)
      disposition = if definition.elaborated then decideOverlap definition.snapshot.overlap definition.snapshot.capacity count else PendingOccurrence
      coalesced = if disposition == CoalescedOccurrence then pending else Nothing
      discarded = disposition == CoalescedOccurrence || disposition == OverflowOccurrence
  now <- databaseNow
  inserted <-
    query
      "INSERT INTO monitor_fires(monitor_id,conversation_id,idempotency_key,scheduled_at,trigger_canonical_message_id,\
      \ trigger_evidence,counted_at_admission,definition_revision,definition_snapshot,disposition,coalesced_into,cancelled_at,last_error)\
      \ VALUES(?,?,?,?,?,?,?,?,?::jsonb,?,?,?,?) ON CONFLICT DO NOTHING RETURNING fire_id"
      ( definition.monitorId,
        definition.conversation,
        draft.key,
        draft.scheduled,
        draft.sourceMessage,
        draft.evidence,
        draft.counted,
        definition.revision,
        jsonText definition.snapshot,
        dispositionText disposition,
        coalesced,
        if discarded && not definition.timed then Just now else Nothing,
        if disposition == OverflowOccurrence then Just ("bounded monitor queue full" :: Text) else Nothing
      )
  pure $ case inserted of [Only fire] -> Just fire; _ -> Nothing

-- | Host entry for a single occurrence. Batched ingest/scheduling callers use
-- insertOccurrenceWithin inside their already-pinned transaction instead.
recordOccurrence :: (WithConnection :> es, IOE :> es) => MonitorId -> OccurrenceDraft -> Eff es (Maybe MonitorFireId)
recordOccurrence monitor draft = withTransaction $ do
  (_ :: [Only Int64]) <- query "SELECT c.conversation_id FROM conversations c JOIN monitors m USING(conversation_id) WHERE m.monitor_id=? FOR UPDATE OF c" (Only monitor)
  definition <- loadDefinition monitor
  maybe (pure Nothing) (`insertOccurrenceWithin` draft) definition
