-- |
-- Read-only diagnostics and explicit, scoped maintenance requests for the
-- unbounded-context projections.  Raw messages are never mutated here.
module Max.ContextAdmin
  ( loadContextStatus,
    listCaptureRunsAdmin,
    listCompartmentsAdmin,
    listPlanTracesAdmin,
    fetchMemoryHistoryAdmin,
    loadEmbeddingStatus,
    runContextIntegrityCheck,
    enqueueContextRebuildAdmin,
    invalidateEmbeddingsAdmin,
  )
where

import Data.Aeson (Value (..), eitherDecodeStrict', object, (.=))
import Data.Int (Int64)
import Data.Maybe (catMaybes)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime)
import Database.PostgreSQL.Simple.FromRow (FromRow (..), field)
import Database.PostgreSQL.Simple.Types (Only (..))
import Effectful
import Effectful.Concurrent (Concurrent)
import Effectful.PostgreSQL (WithConnection, execute, query)
import Max.ContextTraceStore (ContextPlanTraceRow (..), listContextPlanTraces)
import Max.ConversationScope (conversationScopeFor)
import Max.DB.History (notForwardChild)
import Max.EpisodeStore
  ( ActiveCompartment (..),
    CaptureReason (CaptureRebuild),
    CaptureRequest (..),
    CaptureRun (..),
    CompartmentId (..),
    enqueueRebuildRun,
    listActiveCompartments,
  )
import Max.Historian (historianPromptVersion, historianSchemaVersion)
import Max.MaintenanceLease
  ( MaintenanceDomain (EmbeddingMaintenance),
    MaintenanceRun (..),
    withMaintenanceFence,
    withMaintenanceLease,
  )
import Max.MemoryStore (MemoryId (..), invalidateMemoryEmbeddingsInConversation)
import OneBot.Types (GroupId (..))

data CoverageRow = CoverageRow
  { coverageConversationId :: !Int64,
    coverageMessageCount :: !Int64,
    coverageFirstSeq :: !(Maybe Int64),
    coverageLastSeq :: !(Maybe Int64),
    coverageLastMessageAt :: !(Maybe UTCTime),
    coverageHistorianCursor :: !(Maybe Int64),
    coverageActiveCompartments :: !Int64,
    coverageActiveStart :: !(Maybe Int64),
    coverageActiveEnd :: !(Maybe Int64),
    coverageGapRanges :: !Int64,
    coverageOverlapRanges :: !Int64,
    coverageUncoveredSettledMessages :: !Int64,
    coverageLiveTailMessages :: !Int64,
    coverageOldestLiveTailAt :: !(Maybe UTCTime),
    coverageMaterializationRevision :: !(Maybe Int64),
    coverageMaterializationEnd :: !(Maybe Int64),
    coverageMaterializationPolicy :: !(Maybe Text),
    coverageMaterializationReason :: !(Maybe Text),
    coverageMaterializationUpdatedAt :: !(Maybe UTCTime),
    coverageMaterializationValid :: !(Maybe Bool)
  }

instance FromRow CoverageRow where
  fromRow =
    CoverageRow
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
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field

loadContextStatus ::
  (WithConnection :> es, IOE :> es) =>
  Maybe Int64 ->
  Eff es Value
loadContextStatus selectedConversation = do
  rows <-
    query
      "WITH conversations AS ( \
      \  SELECT group_id AS conversation_id FROM messages \
      \  UNION SELECT group_id FROM sessions \
      \  UNION SELECT conversation_id FROM conversation_cursors \
      \  UNION SELECT conversation_id FROM conversation_compartments \
      \), message_stats AS ( \
      \  SELECT group_id AS conversation_id, count(*) AS message_count, \
      \         min(ingest_seq) AS first_seq, max(ingest_seq) AS last_seq, \
      \         max(received_at) AS last_message_at \
      \  FROM messages GROUP BY group_id \
      \), historian AS ( \
      \  SELECT conversation_id, ingest_seq FROM conversation_cursors WHERE cursor_name = 'historian' \
      \), active AS ( \
      \  SELECT conversation_id, count(*) AS active_count, min(start_ingest_seq) AS active_start, \
      \         max(end_ingest_seq) AS active_end \
      \  FROM conversation_compartments WHERE state = 'active' GROUP BY conversation_id \
      \), ordered_ranges AS ( \
      \  SELECT conversation_id, start_ingest_seq, end_ingest_seq, \
      \         lag(end_ingest_seq) OVER (PARTITION BY conversation_id ORDER BY start_ingest_seq, end_ingest_seq) AS previous_end \
      \  FROM conversation_compartments WHERE state = 'active' \
      \), range_health AS ( \
      \  SELECT current.conversation_id, \
      \         count(*) FILTER (WHERE current.previous_end IS NOT NULL AND current.previous_end >= current.start_ingest_seq) AS overlaps, \
      \         count(*) FILTER (WHERE current.previous_end IS NOT NULL AND current.previous_end < current.start_ingest_seq \
      \           AND EXISTS (SELECT 1 FROM messages AS gap_message \
      \                       WHERE gap_message.group_id = current.conversation_id \
      \                         AND gap_message.ingest_seq > current.previous_end \
      \                         AND gap_message.ingest_seq < current.start_ingest_seq)) AS gaps \
      \  FROM ordered_ranges AS current GROUP BY current.conversation_id \
      \), coverage AS ( \
      \  SELECT conversations.conversation_id, \
      \         count(message.*) FILTER (WHERE message.ingest_seq <= COALESCE(historian.ingest_seq, 0) \
      \           AND NOT EXISTS (SELECT 1 FROM conversation_compartments AS owner \
      \                           WHERE owner.conversation_id = conversations.conversation_id \
      \                             AND owner.state = 'active' \
      \                             AND message.ingest_seq BETWEEN owner.start_ingest_seq AND owner.end_ingest_seq)) AS uncovered_settled, \
      \         count(message.*) FILTER (WHERE message.ingest_seq > COALESCE(historian.ingest_seq, 0)) AS live_tail, \
      \         min(message.received_at) FILTER (WHERE message.ingest_seq > COALESCE(historian.ingest_seq, 0)) AS oldest_live_tail_at \
      \  FROM conversations \
      \  LEFT JOIN historian USING (conversation_id) \
      \  LEFT JOIN messages AS message ON message.group_id = conversations.conversation_id \
      \  GROUP BY conversations.conversation_id \
      \) \
      \ SELECT conversations.conversation_id, COALESCE(message_stats.message_count, 0), \
      \        message_stats.first_seq, message_stats.last_seq, message_stats.last_message_at, \
      \        historian.ingest_seq, COALESCE(active.active_count, 0), active.active_start, active.active_end, \
      \        COALESCE(range_health.gaps, 0), COALESCE(range_health.overlaps, 0), \
      \        coverage.uncovered_settled, coverage.live_tail, coverage.oldest_live_tail_at, \
      \        materialization.revision, materialization.end_ingest_seq, materialization.policy_version, \
      \        materialization.reason, materialization.updated_at, \
      \        CASE WHEN materialization.conversation_id IS NULL THEN NULL ELSE ( \
      \          EXISTS (SELECT 1 FROM conversation_compartments AS ending \
      \                  WHERE ending.conversation_id = conversations.conversation_id \
      \                    AND ending.state = 'active' \
      \                    AND ending.end_ingest_seq = materialization.end_ingest_seq) \
      \          AND NOT EXISTS ( \
      \            SELECT 1 FROM jsonb_array_elements(materialization.items) AS item \
      \            LEFT JOIN conversation_compartments AS source \
      \              ON source.id = (item->>'compartment_id')::bigint \
      \             AND source.conversation_id = conversations.conversation_id \
      \             AND source.state = 'active' \
      \             AND source.materialization_version = (item->>'projection_version')::bigint \
      \            WHERE source.id IS NULL \
      \          ) \
      \        ) END AS materialization_valid \
      \ FROM conversations \
      \ LEFT JOIN message_stats USING (conversation_id) \
      \ LEFT JOIN historian USING (conversation_id) \
      \ LEFT JOIN active USING (conversation_id) \
      \ LEFT JOIN range_health USING (conversation_id) \
      \ LEFT JOIN coverage USING (conversation_id) \
      \ LEFT JOIN context_materializations AS materialization USING (conversation_id) \
      \ WHERE (?::bigint IS NULL OR conversations.conversation_id = ?) \
      \ ORDER BY conversations.conversation_id"
      (selectedConversation, selectedConversation)
  leases <-
    query
      "SELECT domain, owner, fencing_token, acquired_at, heartbeat_at, expires_at, expires_at > now() \
      \ FROM maintenance_leases ORDER BY domain"
      ()
  captureLeases <-
    query
      "SELECT lease_owner, count(*), min(lease_expires_at), max(lease_expires_at) \
      \ FROM episode_capture_runs \
      \ WHERE status IN ('leased', 'generated') AND lease_owner IS NOT NULL \
      \ GROUP BY lease_owner ORDER BY lease_owner"
      ()
  legacyArtifacts <-
    query
      "SELECT \
      \  (SELECT count(*) FROM information_schema.columns \
      \   WHERE table_schema = current_schema() AND table_name = 'sessions' \
      \     AND column_name IN ('context_anchor', 'memx_anchor')), \
      \  (SELECT count(*) FROM conversation_cursors WHERE cursor_name = 'memory_extract')"
      ()
  let statuses = map coverageJson (rows :: [CoverageRow])
      unhealthy = length [() | row <- rows, not (null (coverageIssues row))]
      (legacyColumns, legacyCursors) = case legacyArtifacts :: [(Int64, Int64)] of
        artifact : _ -> artifact
        [] -> (0, 0)
  pure $
    object
      [ "summary"
          .= object
            [ "conversations" .= length rows,
              "healthy" .= (length rows - unhealthy),
              "with_issues" .= unhealthy
            ],
        "conversations" .= statuses,
        "maintenance_leases"
          .= [ object
                 [ "domain" .= domain,
                   "owner" .= owner,
                   "fencing_token" .= token,
                   "acquired_at" .= acquired,
                   "heartbeat_at" .= heartbeat,
                   "expires_at" .= expires,
                   "active" .= activeLease
                 ]
             | (domain, owner, token, acquired, heartbeat, expires, activeLease) <- leases :: [(Text, Text, Int64, UTCTime, UTCTime, UTCTime, Bool)]
             ],
        "capture_workers"
          .= [ object
                 [ "owner" .= owner,
                   "leased_runs" .= count,
                   "first_expiry" .= firstExpiry,
                   "last_expiry" .= lastExpiry
                 ]
             | (owner, count, firstExpiry, lastExpiry) <- captureLeases :: [(Text, Int64, Maybe UTCTime, Maybe UTCTime)]
             ],
        "cutover"
          .= object
            [ "context_protocol_version" .= ("unbounded-context/v1" :: Text),
              "reader_mode" .= ("all_conversations" :: Text),
              "legacy_extractor_running" .= (legacyCursors > 0),
              "legacy_session_anchor_columns" .= legacyColumns,
              "legacy_memory_cursor_rows" .= legacyCursors,
              "old_new_worker_conflict" .= (legacyColumns > 0 || legacyCursors > 0)
            ]
      ]

coverageJson :: CoverageRow -> Value
coverageJson row =
  object
    [ "conversation_id" .= row.coverageConversationId,
      "message_count" .= row.coverageMessageCount,
      "first_ingest_seq" .= row.coverageFirstSeq,
      "last_ingest_seq" .= row.coverageLastSeq,
      "last_message_at" .= row.coverageLastMessageAt,
      "historian_cursor" .= row.coverageHistorianCursor,
      "active_compartments" .= row.coverageActiveCompartments,
      "active_start_ingest_seq" .= row.coverageActiveStart,
      "active_end_ingest_seq" .= row.coverageActiveEnd,
      "gap_ranges" .= row.coverageGapRanges,
      "overlap_ranges" .= row.coverageOverlapRanges,
      "uncovered_settled_messages" .= row.coverageUncoveredSettledMessages,
      "live_tail_messages" .= row.coverageLiveTailMessages,
      "oldest_live_tail_at" .= row.coverageOldestLiveTailAt,
      "materialization"
        .= object
          [ "revision" .= row.coverageMaterializationRevision,
            "end_ingest_seq" .= row.coverageMaterializationEnd,
            "policy_version" .= row.coverageMaterializationPolicy,
            "reason" .= row.coverageMaterializationReason,
            "updated_at" .= row.coverageMaterializationUpdatedAt,
            "valid" .= row.coverageMaterializationValid
          ],
      "issues" .= coverageIssues row
    ]

coverageIssues :: CoverageRow -> [Text]
coverageIssues row =
  catMaybes
    [ issue (row.coverageOverlapRanges > 0) "active compartment ranges overlap",
      issue (row.coverageGapRanges > 0) "raw messages exist between active compartment ranges",
      issue (row.coverageUncoveredSettledMessages > 0) "settled messages are not owned by an active compartment",
      issue (row.coverageHistorianCursor > row.coverageLastSeq) "historian cursor is beyond the source ledger",
      issue (row.coverageMaterializationValid == Just False) "materialization references stale or inactive compartments"
    ]
  where
    issue condition message = if condition then Just message else Nothing

data CaptureAdminRow = CaptureAdminRow
  { captureAdminId :: !Int64,
    captureAdminConversationId :: !Int64,
    captureAdminExpectedCursor :: !Int64,
    captureAdminStart :: !Int64,
    captureAdminEnd :: !Int64,
    captureAdminMessageCount :: !Int,
    captureAdminReason :: !Text,
    captureAdminStatus :: !Text,
    captureAdminAttempt :: !Int,
    captureAdminLeaseOwner :: !(Maybe Text),
    captureAdminLeaseExpiresAt :: !(Maybe UTCTime),
    captureAdminNextRetryAt :: !(Maybe UTCTime),
    captureAdminLastError :: !(Maybe Text),
    captureAdminProfile :: !Text,
    captureAdminPromptVersion :: !Text,
    captureAdminSchemaVersion :: !Int,
    captureAdminValidationErrors :: !Text,
    captureAdminReplaces :: !(Maybe Int64),
    captureAdminPublished :: !(Maybe Int64),
    captureAdminCreatedAt :: !UTCTime,
    captureAdminUpdatedAt :: !UTCTime,
    captureAdminPublishedAt :: !(Maybe UTCTime)
  }

instance FromRow CaptureAdminRow where
  fromRow =
    CaptureAdminRow
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

listCaptureRunsAdmin ::
  (WithConnection :> es, IOE :> es) =>
  Maybe Int64 ->
  Int ->
  Eff es [Value]
listCaptureRunsAdmin conversationId requestedLimit = do
  rows <-
    query
      "SELECT id, conversation_id, expected_cursor_seq, start_ingest_seq, end_ingest_seq, \
      \       source_message_count, scheduling_reason, status, attempt, lease_owner, lease_expires_at, \
      \       next_retry_at, last_error, historian_profile, prompt_version, schema_version, \
      \       validation_errors::text, replaces_compartment_id, published_compartment_id, \
      \       created_at, updated_at, published_at \
      \ FROM episode_capture_runs \
      \ WHERE (?::bigint IS NULL OR conversation_id = ?) \
      \ ORDER BY id DESC LIMIT ?"
      (conversationId, conversationId, max 1 (min 500 requestedLimit))
  traverse captureJson (rows :: [CaptureAdminRow])

captureJson :: CaptureAdminRow -> Eff es Value
captureJson row = do
  validation <- decodeJson row.captureAdminValidationErrors
  pure $
    object
      [ "id" .= row.captureAdminId,
        "conversation_id" .= row.captureAdminConversationId,
        "expected_cursor" .= row.captureAdminExpectedCursor,
        "start_ingest_seq" .= row.captureAdminStart,
        "end_ingest_seq" .= row.captureAdminEnd,
        "source_message_count" .= row.captureAdminMessageCount,
        "reason" .= row.captureAdminReason,
        "status" .= row.captureAdminStatus,
        "attempt" .= row.captureAdminAttempt,
        "lease_owner" .= row.captureAdminLeaseOwner,
        "lease_expires_at" .= row.captureAdminLeaseExpiresAt,
        "next_retry_at" .= row.captureAdminNextRetryAt,
        "last_error" .= row.captureAdminLastError,
        "historian_profile" .= row.captureAdminProfile,
        "prompt_version" .= row.captureAdminPromptVersion,
        "schema_version" .= row.captureAdminSchemaVersion,
        "validation_errors" .= validation,
        "replaces_compartment_id" .= row.captureAdminReplaces,
        "published_compartment_id" .= row.captureAdminPublished,
        "created_at" .= row.captureAdminCreatedAt,
        "updated_at" .= row.captureAdminUpdatedAt,
        "published_at" .= row.captureAdminPublishedAt
      ]

listCompartmentsAdmin ::
  (WithConnection :> es, IOE :> es) =>
  Maybe Int64 ->
  Int ->
  Eff es [Value]
listCompartmentsAdmin conversationId requestedLimit = do
  rows <-
    query
      "SELECT compartment.id, compartment.conversation_id, compartment.start_ingest_seq, compartment.end_ingest_seq, \
      \       compartment.source_message_count, compartment.episode_kind, compartment.importance, compartment.confidence, \
      \       compartment.state, compartment.superseded_by, compartment.historian_profile, compartment.prompt_version, \
      \       compartment.schema_version, compartment.materialization_version, compartment.expand_handle::text, \
      \       compartment.embedding_model, compartment.embedding_dimensions, compartment.embedding_content_hash, \
      \       compartment.created_at, compartment.activated_at, count(evidence.*) \
      \ FROM conversation_compartments AS compartment \
      \ LEFT JOIN compartment_evidence AS evidence ON evidence.compartment_id = compartment.id \
      \ WHERE (?::bigint IS NULL OR compartment.conversation_id = ?) \
      \ GROUP BY compartment.id \
      \ ORDER BY compartment.id DESC LIMIT ?"
      (conversationId, conversationId, max 1 (min 500 requestedLimit))
  pure (map compartmentAdminJson (rows :: [CompartmentAdminRow]))

data CompartmentAdminRow = CompartmentAdminRow
  { compartmentAdminId :: !Int64,
    compartmentAdminConversationId :: !Int64,
    compartmentAdminStart :: !Int64,
    compartmentAdminEnd :: !Int64,
    compartmentAdminMessageCount :: !Int,
    compartmentAdminKind :: !Text,
    compartmentAdminImportance :: !Double,
    compartmentAdminConfidence :: !Double,
    compartmentAdminState :: !Text,
    compartmentAdminSupersededBy :: !(Maybe Int64),
    compartmentAdminProfile :: !Text,
    compartmentAdminPromptVersion :: !Text,
    compartmentAdminSchemaVersion :: !Int,
    compartmentAdminMaterializationVersion :: !Int64,
    compartmentAdminExpandHandle :: !Text,
    compartmentAdminEmbeddingModel :: !(Maybe Text),
    compartmentAdminEmbeddingDimensions :: !(Maybe Int),
    compartmentAdminEmbeddingHash :: !(Maybe Text),
    compartmentAdminCreatedAt :: !UTCTime,
    compartmentAdminActivatedAt :: !(Maybe UTCTime),
    compartmentAdminEvidenceCount :: !Int64
  }

instance FromRow CompartmentAdminRow where
  fromRow =
    CompartmentAdminRow
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
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field

compartmentAdminJson :: CompartmentAdminRow -> Value
compartmentAdminJson row =
  object
    [ "id" .= row.compartmentAdminId,
      "conversation_id" .= row.compartmentAdminConversationId,
      "start_ingest_seq" .= row.compartmentAdminStart,
      "end_ingest_seq" .= row.compartmentAdminEnd,
      "source_message_count" .= row.compartmentAdminMessageCount,
      "episode_kind" .= row.compartmentAdminKind,
      "importance" .= row.compartmentAdminImportance,
      "confidence" .= row.compartmentAdminConfidence,
      "state" .= row.compartmentAdminState,
      "superseded_by" .= row.compartmentAdminSupersededBy,
      "historian_profile" .= row.compartmentAdminProfile,
      "prompt_version" .= row.compartmentAdminPromptVersion,
      "schema_version" .= row.compartmentAdminSchemaVersion,
      "materialization_version" .= row.compartmentAdminMaterializationVersion,
      "expand_handle" .= row.compartmentAdminExpandHandle,
      "embedding_model" .= row.compartmentAdminEmbeddingModel,
      "embedding_dimensions" .= row.compartmentAdminEmbeddingDimensions,
      "embedding_content_hash" .= row.compartmentAdminEmbeddingHash,
      "created_at" .= row.compartmentAdminCreatedAt,
      "activated_at" .= row.compartmentAdminActivatedAt,
      "evidence_links" .= row.compartmentAdminEvidenceCount
    ]

listPlanTracesAdmin ::
  (WithConnection :> es, IOE :> es) =>
  Maybe Int64 ->
  Int ->
  Eff es [Value]
listPlanTracesAdmin conversationId limit =
  map planTraceJson <$> listContextPlanTraces conversationId limit

planTraceJson :: ContextPlanTraceRow -> Value
planTraceJson trace =
  object
    [ "id" .= trace.cptrId,
      "conversation_id" .= trace.cptrConversationId,
      "trigger_message_id" .= trace.cptrTriggerMessageId,
      "history_mode" .= trace.cptrHistoryMode,
      "policy_version" .= trace.cptrPolicyVersion,
      "materialization_revision" .= trace.cptrMaterializationRevision,
      "materialization_reason" .= trace.cptrMaterializationReason,
      "estimated_prompt_tokens" .= trace.cptrEstimatedPromptTokens,
      "prompt_token_limit" .= trace.cptrPromptTokenLimit,
      "max_input_tokens" .= trace.cptrMaxInputTokens,
      "reserved_output_tokens" .= trace.cptrReservedOutputTokens,
      "attachment_reserve" .= trace.cptrAttachmentReserve,
      "tool_round_reserve" .= trace.cptrToolRoundReserve,
      "within_budget" .= trace.cptrWithinBudget,
      "decisions" .= trace.cptrDecisions,
      "created_at" .= trace.cptrCreatedAt
    ]

fetchMemoryHistoryAdmin ::
  (WithConnection :> es, IOE :> es) =>
  MemoryId ->
  Eff es (Maybe Value)
fetchMemoryHistoryAdmin memoryId = do
  currentRows <-
    query
      "SELECT id, version, scope, scope_id, source_group_id, content, lifecycle, category, \
      \       superseded_by, embedding_model, embedding_dimensions, embedding_content_hash, updated_at \
      \ FROM memories WHERE id = ?"
      (Only memoryId)
  case currentRows :: [(Int64, Int64, Text, Int64, Maybe Int64, Text, Text, Maybe Text, Maybe Int64, Maybe Text, Maybe Int, Maybe Text, UTCTime)] of
    [] -> pure Nothing
    (mid, version, scope, scopeId, sourceGroup, content, lifecycle, category, supersededBy, embeddingModel, embeddingDimensions, embeddingHash, updatedAt) : _ -> do
      versions <-
        query
          "SELECT version, content, lifecycle, category, superseded_by, created_at \
          \ FROM memory_versions WHERE memory_id = ? ORDER BY version DESC"
          (Only memoryId)
      evidence <-
        query
          "SELECT id, memory_version, evidence_kind, source_conversation_id, source_principal_id, \
          \       source_canonical_message_id, source_start_ingest_seq, source_end_ingest_seq, source_episode_id, note, created_at \
          \ FROM memory_evidence WHERE memory_id = ? ORDER BY id DESC"
          (Only memoryId)
      mutations <-
        query
          "SELECT id, from_version, to_version, operation, actor_kind, actor_principal_id, conversation_id, reason, created_at \
          \ FROM memory_mutations WHERE memory_id = ? ORDER BY id DESC"
          (Only memoryId)
      pure . Just $
        object
          [ "current"
              .= object
                [ "id" .= mid,
                  "version" .= version,
                  "scope" .= scope,
                  "scope_id" .= scopeId,
                  "source_group_id" .= sourceGroup,
                  "content" .= content,
                  "lifecycle" .= lifecycle,
                  "category" .= category,
                  "superseded_by" .= supersededBy,
                  "embedding_model" .= embeddingModel,
                  "embedding_dimensions" .= embeddingDimensions,
                  "embedding_content_hash" .= embeddingHash,
                  "updated_at" .= updatedAt
                ],
            "versions"
              .= [ object
                     [ "version" .= itemVersion,
                       "content" .= itemContent,
                       "lifecycle" .= itemLifecycle,
                       "category" .= itemCategory,
                       "superseded_by" .= itemSupersededBy,
                       "created_at" .= createdAt
                     ]
                 | (itemVersion, itemContent, itemLifecycle, itemCategory, itemSupersededBy, createdAt) <- versions :: [(Int64, Text, Text, Maybe Text, Maybe Int64, UTCTime)]
                 ],
            "evidence"
              .= [ object
                     [ "id" .= evidenceId,
                       "memory_version" .= evidenceVersion,
                       "kind" .= kind,
                       "source_conversation_id" .= sourceConversation,
                       "source_principal_id" .= sourcePrincipal,
                       "source_message_id" .= sourceMessage,
                       "source_start_ingest_seq" .= sourceStart,
                       "source_end_ingest_seq" .= sourceEnd,
                       "source_episode_id" .= sourceEpisode,
                       "note" .= note,
                       "created_at" .= createdAt
                     ]
                 | (evidenceId, evidenceVersion, kind, sourceConversation, sourcePrincipal, sourceMessage, sourceStart, sourceEnd, sourceEpisode, note, createdAt) <-
                     evidence :: [(Int64, Int64, Text, Maybe Int64, Maybe Int64, Maybe Int64, Maybe Int64, Maybe Int64, Maybe Int64, Maybe Text, UTCTime)]
                 ],
            "mutations"
              .= [ object
                     [ "id" .= mutationId,
                       "from_version" .= fromVersion,
                       "to_version" .= toVersion,
                       "operation" .= operation,
                       "actor_kind" .= actorKind,
                       "actor_principal_id" .= actorPrincipal,
                       "conversation_id" .= conversation,
                       "reason" .= reason,
                       "created_at" .= createdAt
                     ]
                 | (mutationId, fromVersion, toVersion, operation, actorKind, actorPrincipal, conversation, reason, createdAt) <-
                     mutations :: [(Int64, Maybe Int64, Int64, Text, Text, Maybe Int64, Maybe Int64, Maybe Text, UTCTime)]
                 ]
          ]

loadEmbeddingStatus ::
  (WithConnection :> es, IOE :> es) =>
  Text ->
  Maybe Int64 ->
  Eff es Value
loadEmbeddingStatus targetModel conversationId = do
  rows <-
    query
      ( "WITH corpus AS ( \
        \  SELECT 'message'::text AS corpus, message.group_id AS conversation_id, message.rendered_text AS content, \
        \         message.embedding IS NOT NULL AS has_embedding, message.embedding_model, message.embedding_dimensions, message.embedding_content_hash \
        \  FROM messages AS message WHERE NOT message.is_synthetic AND "
          <> notForwardChild "message"
          <> " \
             \    AND char_length(message.rendered_text) >= 4 \
             \  UNION ALL \
             \  SELECT 'memory', COALESCE(memory.source_group_id, memory.scope_id), memory.content, \
             \         memory.embedding IS NOT NULL, memory.embedding_model, memory.embedding_dimensions, memory.embedding_content_hash \
             \  FROM memories AS memory WHERE memory.lifecycle IN ('active', 'permanent') \
             \  UNION ALL \
             \  SELECT 'episode', episode.conversation_id, episode.summary_p1, \
             \         episode.embedding IS NOT NULL, episode.embedding_model, episode.embedding_dimensions, episode.embedding_content_hash \
             \  FROM conversation_compartments AS episode WHERE episode.state = 'active' \
             \  UNION ALL \
             \  SELECT 'sticker', NULL::bigint, sticker.description, \
             \         sticker.embedding IS NOT NULL, sticker.embedding_model, sticker.embedding_dimensions, sticker.embedding_content_hash \
             \  FROM stickers AS sticker WHERE sticker.description IS NOT NULL AND NOT sticker.banned \
             \), classified AS ( \
             \  SELECT corpus.*, encode(digest(convert_to(corpus.content, 'UTF8'), 'sha256'), 'hex') AS expected_hash \
             \  FROM corpus WHERE (?::bigint IS NULL OR corpus.conversation_id = ?) \
             \) \
             \ SELECT corpus, count(*) AS total, \
             \        count(*) FILTER (WHERE has_embedding AND embedding_model = ? AND embedding_content_hash = expected_hash) AS ready, \
             \        count(*) FILTER (WHERE NOT has_embedding OR embedding_model IS DISTINCT FROM ? OR embedding_content_hash IS DISTINCT FROM expected_hash) AS pending, \
             \        count(*) FILTER (WHERE has_embedding AND embedding_content_hash IS DISTINCT FROM expected_hash) AS stale_hash, \
             \        string_agg(DISTINCT COALESCE(embedding_model, '(pending)') || ':' || COALESCE(embedding_dimensions::text, '-'), ', ' ORDER BY COALESCE(embedding_model, '(pending)') || ':' || COALESCE(embedding_dimensions::text, '-')) AS stored_spaces \
             \ FROM classified GROUP BY corpus ORDER BY corpus"
      )
      (conversationId, conversationId, targetModel, targetModel)
  pure $
    object
      [ "target_model" .= targetModel,
        "conversation_id" .= conversationId,
        "corpora"
          .= [ object
                 [ "corpus" .= corpus,
                   "total" .= total,
                   "ready" .= ready,
                   "pending" .= pending,
                   "stale_content_hash" .= staleHash,
                   "stored_spaces" .= storedSpaces
                 ]
             | (corpus, total, ready, pending, staleHash, storedSpaces) <- rows :: [(Text, Int64, Int64, Int64, Int64, Maybe Text)]
             ]
      ]

runContextIntegrityCheck ::
  (WithConnection :> es, IOE :> es) =>
  Maybe Int64 ->
  Eff es Value
runContextIntegrityCheck conversationId = do
  rows <-
    query
      "WITH conversations AS ( \
      \  SELECT group_id AS conversation_id FROM messages \
      \  UNION SELECT conversation_id FROM conversation_cursors \
      \  UNION SELECT conversation_id FROM conversation_compartments \
      \), historian AS ( \
      \  SELECT conversation_id, ingest_seq FROM conversation_cursors WHERE cursor_name = 'historian' \
      \) \
      \ SELECT conversations.conversation_id, \
      \   (SELECT count(*) FROM conversation_compartments AS compartment \
      \    WHERE compartment.conversation_id = conversations.conversation_id AND compartment.state = 'active' \
      \      AND (compartment.source_hash IS DISTINCT FROM conversation_source_hash(compartment.conversation_id, compartment.start_ingest_seq, compartment.end_ingest_seq) \
      \        OR compartment.source_message_count IS DISTINCT FROM (SELECT count(*) FROM messages AS source WHERE source.group_id = compartment.conversation_id AND source.ingest_seq BETWEEN compartment.start_ingest_seq AND compartment.end_ingest_seq))) AS bad_source_ranges, \
      \   (SELECT count(*) FROM conversation_compartments AS left_range JOIN conversation_compartments AS right_range \
      \      ON left_range.conversation_id = right_range.conversation_id AND left_range.id < right_range.id \
      \     AND left_range.source_range && right_range.source_range \
      \    WHERE left_range.conversation_id = conversations.conversation_id AND left_range.state = 'active' AND right_range.state = 'active') AS overlaps, \
      \   (SELECT count(*) FROM messages AS message \
      \    WHERE message.group_id = conversations.conversation_id \
      \      AND message.ingest_seq <= COALESCE(historian.ingest_seq, 0) \
      \      AND NOT EXISTS (SELECT 1 FROM conversation_compartments AS owner \
      \                      WHERE owner.conversation_id = conversations.conversation_id AND owner.state = 'active' \
      \                        AND message.ingest_seq BETWEEN owner.start_ingest_seq AND owner.end_ingest_seq)) AS uncovered_settled, \
      \   (COALESCE(historian.ingest_seq, 0) > COALESCE((SELECT max(ingest_seq) FROM messages AS source WHERE source.group_id = conversations.conversation_id), 0)) AS cursor_beyond_ledger, \
      \   (SELECT count(*) FROM context_materializations AS materialization \
      \    WHERE materialization.conversation_id = conversations.conversation_id \
      \      AND (NOT EXISTS (SELECT 1 FROM conversation_compartments AS ending \
      \                       WHERE ending.conversation_id = conversations.conversation_id AND ending.state = 'active' \
      \                         AND ending.end_ingest_seq = materialization.end_ingest_seq) \
      \        OR EXISTS (SELECT 1 FROM jsonb_array_elements(materialization.items) AS item \
      \                   LEFT JOIN conversation_compartments AS source \
      \                     ON source.id = (item->>'compartment_id')::bigint \
      \                    AND source.conversation_id = conversations.conversation_id AND source.state = 'active' \
      \                    AND source.materialization_version = (item->>'projection_version')::bigint \
      \                   WHERE source.id IS NULL))) AS bad_materializations \
      \ FROM conversations LEFT JOIN historian USING (conversation_id) \
      \ WHERE (?::bigint IS NULL OR conversations.conversation_id = ?) \
      \ ORDER BY conversations.conversation_id"
      (conversationId, conversationId)
  memoryProjectionMismatch <-
    query
      "SELECT count(*) FROM memories AS memory \
      \ LEFT JOIN memory_versions AS version ON version.memory_id = memory.id AND version.version = memory.version \
      \ WHERE (?::bigint IS NULL OR (memory.scope = 'group' AND memory.scope_id = ?) \
      \                         OR (memory.scope = 'user' AND memory.source_group_id = ?)) \
      \   AND (version.memory_id IS NULL OR memory.content IS DISTINCT FROM version.content \
      \    OR memory.lifecycle IS DISTINCT FROM version.lifecycle OR memory.category IS DISTINCT FROM version.category \
      \    OR memory.superseded_by IS DISTINCT FROM version.superseded_by)"
      (conversationId, conversationId, conversationId)
  let typedRows = rows :: [(Int64, Int64, Int64, Int64, Bool, Int64)]
      conversations =
        [ object
            [ "conversation_id" .= groupId,
              "bad_source_ranges" .= badSource,
              "overlap_ranges" .= overlaps,
              "uncovered_settled_messages" .= uncovered,
              "cursor_beyond_ledger" .= cursorBeyond,
              "bad_materializations" .= badMaterializations,
              "ok" .= (badSource == 0 && overlaps == 0 && uncovered == 0 && not cursorBeyond && badMaterializations == 0)
            ]
        | (groupId, badSource, overlaps, uncovered, cursorBeyond, badMaterializations) <- typedRows
        ]
      memoryMismatch = case memoryProjectionMismatch :: [Only Int64] of
        Only count : _ -> count
        [] -> 0
      allHealthy =
        all
          ( \(_, badSource, overlaps, uncovered, cursorBeyond, badMaterializations) ->
              badSource == 0 && overlaps == 0 && uncovered == 0 && not cursorBeyond && badMaterializations == 0
          )
          typedRows
          && memoryMismatch == 0
  pure $
    object
      [ "ok" .= allHealthy,
        "conversations" .= conversations,
        "memory_current_projection_mismatches" .= memoryMismatch
      ]

enqueueContextRebuildAdmin ::
  (WithConnection :> es, IOE :> es) =>
  Int64 ->
  Maybe CompartmentId ->
  Text ->
  Text ->
  Eff es [CaptureRun]
enqueueContextRebuildAdmin conversationId selectedCompartment profile operationKey = do
  let scope = conversationScopeFor (GroupId conversationId)
      request =
        CaptureRequest
          { requestReason = CaptureRebuild,
            requestHistorianProfile = profile,
            requestPromptVersion = historianPromptVersion,
            requestSchemaVersion = historianSchemaVersion
          }
  active <- listActiveCompartments scope
  let selected = case selectedCompartment of
        Nothing -> active
        Just wanted -> filter ((== wanted) . (.activeCompartmentId)) active
  catMaybes
    <$> traverse
      (\compartment -> enqueueRebuildRun scope compartment.activeCompartmentId operationKey request)
      selected

invalidateEmbeddingsAdmin ::
  (Concurrent :> es, WithConnection :> es, IOE :> es) =>
  Int64 ->
  [Text] ->
  Eff es (Either Text Value)
invalidateEmbeddingsAdmin conversationId requestedCorpora =
  withMaintenanceLease
    EmbeddingMaintenance
    ("admin-reindex:" <> T.pack (show conversationId))
    60
    invalidate
    >>= \case
      MaintenanceUnavailable -> pure (Left "embedding maintenance is busy; retry after the current worker batch")
      MaintenanceLeaseLost -> pure (Left "embedding maintenance lease was lost; the transaction was cancelled")
      MaintenanceCompleted result -> pure result
  where
    invalidate lease =
      withMaintenanceFence lease invalidateHeld >>= \case
        Nothing -> pure (Left "embedding maintenance lease expired before invalidation began")
        Just result -> pure result

    invalidateHeld = do
      let corpora = if null requestedCorpora then ["memory"] else requestedCorpora
          invalid = filter (`notElem` ["message", "memory", "episode"]) corpora
      if not (null invalid)
        then pure (Left ("unsupported corpora: " <> T.intercalate ", " invalid))
        else do
          messages <-
            if "message" `elem` corpora
              then execute "UPDATE messages SET embedding = NULL, embedding_model = NULL, embedding_dimensions = NULL, embedding_content_hash = NULL, embedding_updated_at = NULL WHERE group_id = ?" (Only conversationId)
              else pure 0
          memories <-
            if "memory" `elem` corpora
              then invalidateMemoryEmbeddingsInConversation (conversationScopeFor (GroupId conversationId))
              else pure 0
          episodes <-
            if "episode" `elem` corpora
              then execute "UPDATE conversation_compartments SET embedding = NULL, embedding_model = NULL, embedding_dimensions = NULL, embedding_content_hash = NULL, embedding_updated_at = NULL WHERE conversation_id = ? AND state = 'active'" (Only conversationId)
              else pure 0
          pure . Right $
            object
              [ "conversation_id" .= conversationId,
                "invalidated"
                  .= object
                    [ "messages" .= messages,
                      "memories" .= memories,
                      "episodes" .= episodes
                    ]
              ]

decodeJson :: Text -> Eff es Value
decodeJson raw = case eitherDecodeStrict' (TE.encodeUtf8 raw) of
  Left err -> error ("invalid stored JSON: " <> err)
  Right value -> pure value
