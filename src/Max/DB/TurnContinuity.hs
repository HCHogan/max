-- | Conversation-scoped read side for ADR 005 E1.  Every model-facing lookup
-- starts from a host-minted 'ConversationScope'; a t# ordinal or reply id is
-- only a selector inside that authority boundary.
module Max.DB.TurnContinuity
  ( ReplyTurnTarget (..),
    replyTurnIsInFlight,
    replyTurnIsFinished,
    resolveReplyTurn,
    setAgentTurnEnvironment,
    recordForkFrom,
    recentTurnDigests,
    continuationDigest,
    replayChain,
    expandTurnTrace,
    pruneTurnArchiveReferences,
  )
where

import Data.Aeson (Value, object, (.=))
import Data.Int (Int64)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime, diffUTCTime)
import Database.PostgreSQL.Simple (In (..), Only (..), Query)
import Database.PostgreSQL.Simple.FromRow (FromRow (..), field)
import Database.PostgreSQL.Simple.Types (PGArray (..))
import Effectful
import Effectful.PostgreSQL (WithConnection, execute, query)
import Max.ConversationScope (ConversationScope, conversationStorageId)
import Max.Platform.Types (CanonicalMessageId (..), PrincipalId (..))
import Max.Turn.Continuity
import Max.Turn.Replay (ReplayCandidate (..))
import Max.Turn.Types

data ReplyTurnTarget = ReplyTurnTarget
  { rttTurn :: !AgentTurnRef,
    rttStatus :: !Text,
    rttProfile :: !(Maybe Text),
    rttStartedAt :: !UTCTime,
    rttFinishedAt :: !(Maybe UTCTime)
  }
  deriving stock (Show, Eq)

replyTurnIsInFlight :: ReplyTurnTarget -> Bool
replyTurnIsInFlight target =
  target.rttStatus `elem` ["starting", "running", "recovery-pending"]

replyTurnIsFinished :: ReplyTurnTarget -> Bool
replyTurnIsFinished = not . replyTurnIsInFlight

-- | Resolve only bot output rows carrying the E0 L3 linkage.  A clear
-- watermark is a visibility cut over the producing turn, not merely over the
-- quoted message timestamp.
resolveReplyTurn ::
  (WithConnection :> es, IOE :> es) =>
  ConversationScope ->
  Maybe UTCTime ->
  CanonicalMessageId ->
  Eff es (Maybe ReplyTurnTarget)
resolveReplyTurn scope cleared (CanonicalMessageId messageId) = do
  rows <- case cleared of
    Nothing -> query base (conversationStorageId scope, messageId)
    Just watermark -> query (base <> " AND t.started_at > ?") (conversationStorageId scope, messageId, watermark)
  pure $ case rows :: [(AgentTurnId, TurnOrdinal, Text, Maybe Text, UTCTime, Maybe UTCTime)] of
    [(turnId, ordinal, status, profile, started, finished)] ->
      Just
        ReplyTurnTarget
          { rttTurn = AgentTurnRef turnId ordinal,
            rttStatus = status,
            rttProfile = profile,
            rttStartedAt = started,
            rttFinishedAt = finished
          }
    _ -> Nothing
  where
    base =
      "SELECT t.turn_id, t.turn_ordinal, t.status, t.profile, t.started_at, t.finished_at \
      \FROM conversations c \
      \JOIN messages m USING (conversation_id) \
      \JOIN agent_turns t ON t.turn_id = m.agent_turn_id AND t.conversation_id = c.conversation_id \
      \WHERE c.legacy_group_id = ? AND m.canonical_message_id = ?"

setAgentTurnEnvironment ::
  (WithConnection :> es, IOE :> es) =>
  AgentTurnRef ->
  Int ->
  Text ->
  Eff es ()
setAgentTurnEnvironment turn promptMajor catalogFingerprint = do
  changed <-
    execute
      "UPDATE agent_turns SET prompt_major = ?, tool_catalog_fingerprint = ? WHERE turn_id = ?"
      (promptMajor, catalogFingerprint, turn.atrTurnId)
  if changed == 1 then pure () else error "setAgentTurnEnvironment: turn not found"

-- | Persist U -> T.  The INSERT .. SELECT and composite FKs both enforce that
-- the two turns belong to this exact conversation.
recordForkFrom ::
  (WithConnection :> es, IOE :> es) =>
  ConversationScope ->
  AgentTurnRef -> -- U, the fresh turn
  AgentTurnRef -> -- T, the finished source turn
  PrincipalId ->
  Eff es Bool
recordForkFrom scope fresh source (PrincipalId createdBy) = do
  changed <-
    execute
      "INSERT INTO turn_edges (conversation_id, from_turn_id, to_turn_id, edge_kind, created_by) \
      \SELECT c.conversation_id, fresh.turn_id, source.turn_id, 'fork-from', ? \
      \FROM conversations c \
      \JOIN agent_turns fresh ON fresh.conversation_id = c.conversation_id AND fresh.turn_id = ? \
      \JOIN agent_turns source ON source.conversation_id = c.conversation_id AND source.turn_id = ? \
      \WHERE c.legacy_group_id = ? \
      \  AND source.status = ANY (ARRAY['succeeded'::text, 'silence'::text, 'failed'::text, \
      \                                 'aborted'::text, 'crashed'::text]) \
      \ON CONFLICT (from_turn_id, to_turn_id, edge_kind) DO NOTHING"
      (createdBy, fresh.atrTurnId, source.atrTurnId, conversationStorageId scope)
  pure (changed == 1)

recentTurnDigests ::
  (WithConnection :> es, IOE :> es) =>
  ConversationScope ->
  Maybe UTCTime ->
  UTCTime ->
  Eff es [TurnDigest]
recentTurnDigests scope cleared now = do
  rows <- case cleared of
    Nothing -> query (recentSql "") (conversationStorageId scope, now)
    Just watermark -> query (recentSql " AND t.started_at > ?") (conversationStorageId scope, now, watermark)
  pure (map turnDigestFromRow rows)

recentSql :: Query -> Query
recentSql clearClause =
  "SELECT t.turn_ordinal, t.status, t.profile, t.started_at, t.finished_at, \
  \       (SELECT count(*) FROM execution_journal j \
  \          WHERE j.turn_id = t.turn_id AND j.event_kind = 'tool_call'), \
  \       COALESCE((SELECT string_agg(handle, ',' ORDER BY handle) FROM ( \
  \         SELECT DISTINCT j.normalized_input->>'sandbox_id' AS handle \
  \         FROM execution_journal j WHERE j.turn_id = t.turn_id \
  \           AND j.event_kind = 'tool_call' AND jsonb_extract_path_text(j.normalized_input, 'sandbox_id') IS NOT NULL \
  \       ) sandbox_refs), ''), \
  \       (SELECT m.canonical_message_id FROM messages m WHERE m.agent_turn_id = t.turn_id \
  \          ORDER BY m.turn_chunk_index DESC LIMIT 1), \
  \       (SELECT split_part(m.rendered_text, E'\\n', 1) FROM messages m WHERE m.agent_turn_id = t.turn_id \
  \          ORDER BY m.turn_chunk_index DESC LIMIT 1) \
  \FROM conversations c JOIN agent_turns t USING (conversation_id) \
  \WHERE c.legacy_group_id = ? \
  \  AND t.status = ANY (ARRAY['succeeded'::text, 'silence'::text, 'failed'::text, \
  \                            'aborted'::text, 'crashed'::text]) \
  \  AND t.started_at >= (?::timestamptz - interval '24 hours') \
  \  AND EXISTS (SELECT 1 FROM execution_journal j WHERE j.turn_id = t.turn_id AND j.event_kind = 'tool_call')"
    <> clearClause
    <> " ORDER BY t.started_at DESC, t.turn_id DESC LIMIT 5"

type TurnDigestRow = (TurnOrdinal, Text, Maybe Text, UTCTime, Maybe UTCTime, Int64, Text, Maybe Int64, Maybe Text)

turnDigestFromRow :: TurnDigestRow -> TurnDigest
turnDigestFromRow (ordinal, status, profile, started, finished, toolCount, sandboxes, outputId, outputLine) =
  TurnDigest
    { tdTurnOrdinal = ordinal,
      tdStatus = status,
      tdProfile = profile,
      tdStartedAt = started,
      tdFinishedAt = finished,
      tdToolCount = toolCount,
      tdSandboxHandles = filter (not . T.null) (T.splitOn "," sandboxes),
      tdLastOutputId = outputId,
      tdLastOutputFirstLine = nonBlank outputLine
    }

continuationDigest ::
  (WithConnection :> es, IOE :> es) =>
  ConversationScope ->
  Maybe UTCTime ->
  CanonicalMessageId ->
  UTCTime ->
  Int ->
  Text ->
  ReplyTurnTarget ->
  Eff es (Maybe ContinuationDigest)
continuationDigest scope cleared currentMessage now currentPrompt currentCatalog target = do
  targetRows <- case cleared of
    Nothing -> query targetSql (conversationStorageId scope, target.rttTurn.atrTurnId)
    Just watermark -> query (targetSql <> " AND t.started_at > ?") (conversationStorageId scope, target.rttTurn.atrTurnId, watermark)
  case targetRows :: [TargetDigestRow] of
    [] -> pure Nothing
    [row] -> build (targetTurnDigest row) row.tdrPromptMajor row.tdrCatalogFingerprint row.tdrFinishedIngestSeq
    _ -> error "continuationDigest: duplicate target"
  where
    -- Spelling the projection identically to TurnDigestRow keeps Level 0 and
    -- Level 1 on one deterministic skeleton.
    targetSql =
      "SELECT t.turn_ordinal, t.status, t.profile, t.started_at, t.finished_at, \
      \       (SELECT count(*) FROM execution_journal j WHERE j.turn_id=t.turn_id AND j.event_kind='tool_call'), \
      \       COALESCE((SELECT string_agg(handle, ',' ORDER BY handle) FROM ( \
      \         SELECT DISTINCT j.normalized_input->>'sandbox_id' AS handle FROM execution_journal j \
      \         WHERE j.turn_id=t.turn_id AND jsonb_extract_path_text(j.normalized_input, 'sandbox_id') IS NOT NULL) refs), ''), \
      \       (SELECT m.canonical_message_id FROM messages m WHERE m.agent_turn_id=t.turn_id ORDER BY m.turn_chunk_index DESC LIMIT 1), \
      \       (SELECT split_part(m.rendered_text, E'\\n', 1) FROM messages m WHERE m.agent_turn_id=t.turn_id ORDER BY m.turn_chunk_index DESC LIMIT 1), \
      \       t.prompt_major, t.tool_catalog_fingerprint, COALESCE(t.finished_ingest_seq, 0) \
      \FROM conversations c JOIN agent_turns t USING (conversation_id) \
      \WHERE c.legacy_group_id=? AND t.turn_id=? \
      \  AND t.status = ANY (ARRAY['succeeded'::text, 'silence'::text, 'failed'::text, \
      \                            'aborted'::text, 'crashed'::text])"

    build turnDigest promptMajor catalogFingerprint finishedIngestSeq = do
      journal <- loadJournal target.rttTurn.atrTurnId
      outputs <- loadOutputs target.rttTurn.atrTurnId
      let finished = fromMaybe target.rttStartedAt target.rttFinishedAt
      (interveningCount, messages) <- loadAmbientMessages scope finishedIngestSeq currentMessage
      sandboxStates <- loadSandboxStates scope target.rttTurn.atrTurnId
      sandboxDrift <- loadSandboxDrift scope target.rttTurn.atrTurnId finished currentMessage
      pure . Just $
        ContinuationDigest
          { cdTurn = turnDigest,
            cdJournal = journal,
            cdOutputs = outputs,
            cdElapsedSeconds = floor (diffUTCTime now finished),
            cdInterveningCount = interveningCount,
            cdInterveningMessages = messages,
            cdSandboxStates = sandboxStates,
            cdSandboxDrift = sandboxDrift,
            cdPromptChanged = Just (promptMajor /= currentPrompt),
            cdCatalogChanged = (/= currentCatalog) <$> catalogFingerprint
          }

loadJournal :: (WithConnection :> es, IOE :> es) => AgentTurnId -> Eff es [JournalDigest]
loadJournal turnId = do
  rows <-
    query
      "SELECT execution_ordinal, event_kind, state, tool_ref, \
      \       NULLIF(left(COALESCE(normalized_input::text, ''), 1200), ''), \
      \       NULLIF(left(COALESCE(result_preview, ''), 1200), ''), \
      \       NULLIF(left(COALESCE(failure_detail, ''), 1200), ''), \
      \       NULLIF(left(COALESCE(observed_manifest::text, ''), 1200), '') \
      \FROM execution_journal WHERE turn_id = ? ORDER BY execution_ordinal LIMIT 200"
      (Only turnId)
  pure
    [ JournalDigest ordinal kind state tool input result failure observed
    | (ordinal, kind, state, tool, input, result, failure, observed) <- rows
    ]

loadOutputs :: (WithConnection :> es, IOE :> es) => AgentTurnId -> Eff es [(Int, Int64, Text)]
loadOutputs turnId =
  query
    "SELECT turn_chunk_index, canonical_message_id, left(rendered_text, 1200) \
    \FROM messages WHERE agent_turn_id = ? ORDER BY turn_chunk_index LIMIT 100"
    (Only turnId)

loadAmbientMessages ::
  (WithConnection :> es, IOE :> es) =>
  ConversationScope ->
  Int64 ->
  CanonicalMessageId ->
  Eff es (Int64, [AmbientMessage])
loadAmbientMessages scope finishedIngestSeq (CanonicalMessageId currentMessage) = do
  counts <- query (ambientSelect "count(*)") (currentMessage, conversationStorageId scope, finishedIngestSeq)
  samples <-
    query
      ( ambientSelect
          "m.canonical_message_id, CASE WHEN m.user_id=m.self_id THEN 'Max' \
          \ELSE COALESCE(NULLIF(m.sender_card,''), NULLIF(m.sender_nickname,''), m.author_principal_id::text) END, \
          \left(m.rendered_text, 240)"
          <> " ORDER BY m.ingest_seq DESC LIMIT 5"
      )
      (currentMessage, conversationStorageId scope, finishedIngestSeq)
  let count = case counts :: [Only Int64] of
        [Only n] -> n
        _ -> 0
  pure
    ( count,
      reverse [AmbientMessage messageId author preview | (messageId, author, preview) <- samples]
    )
  where
    ambientSelect projection =
      "SELECT " <> projection <> " FROM messages m \
      \JOIN messages current ON current.canonical_message_id = ? AND current.conversation_id = m.conversation_id \
      \JOIN conversations c ON c.conversation_id = m.conversation_id \
      \WHERE c.legacy_group_id = ? AND m.ingest_seq > ? AND m.ingest_seq < current.ingest_seq \
      \  AND m.canonical_message_id <> current.canonical_message_id \
      \  AND NOT m.is_synthetic AND m.kind IN ('chat','system')"

loadSandboxStates ::
  (WithConnection :> es, IOE :> es) =>
  ConversationScope ->
  AgentTurnId ->
  Eff es [SandboxState]
loadSandboxStates scope turnId = do
  rows <-
    query
      "SELECT refs.handle, COALESCE(sb.status, 'missing') \
      \FROM (SELECT DISTINCT normalized_input->>'sandbox_id' AS handle \
      \      FROM execution_journal WHERE turn_id=? AND jsonb_extract_path_text(normalized_input, 'sandbox_id') IS NOT NULL) refs \
      \JOIN conversations c ON c.legacy_group_id=? \
      \LEFT JOIN sandboxes sb ON sb.conversation_id=c.conversation_id AND sb.sandbox_handle=refs.handle \
      \ORDER BY refs.handle"
      (turnId, conversationStorageId scope)
  pure [SandboxState handle status | (handle, status) <- rows]

loadSandboxDrift ::
  (WithConnection :> es, IOE :> es) =>
  ConversationScope ->
  AgentTurnId ->
  UTCTime ->
  CanonicalMessageId ->
  Eff es [SandboxDrift]
loadSandboxDrift scope sourceTurn finished (CanonicalMessageId currentMessage) = do
  handles <-
    query
      "SELECT DISTINCT normalized_input->>'sandbox_id' FROM execution_journal \
      \WHERE turn_id=? AND jsonb_extract_path_text(normalized_input, 'sandbox_id') IS NOT NULL"
      (Only sourceTurn)
  case [handle | Only handle <- handles, not (T.null handle)] of
    [] -> pure []
    refs -> do
      rows <-
        query
          "SELECT j.normalized_input->>'sandbox_id', t.turn_ordinal, j.finished_at, \
          \       left(j.observed_manifest::text, 1200) \
          \FROM execution_journal j \
          \JOIN agent_turns t ON t.turn_id=j.turn_id \
          \JOIN conversations c ON c.conversation_id=t.conversation_id \
          \JOIN messages current ON current.canonical_message_id=? AND current.conversation_id=c.conversation_id \
          \WHERE c.legacy_group_id=? AND j.turn_id<>? AND j.observed_manifest IS NOT NULL \
          \  AND j.normalized_input->>'sandbox_id' IN ? \
          \  AND j.finished_at>? AND j.finished_at<current.received_at \
          \ORDER BY j.finished_at LIMIT 20"
          (currentMessage, conversationStorageId scope, sourceTurn, In refs, finished)
      pure [SandboxDrift handle ordinal at manifest | (handle, ordinal, at, manifest) <- rows]

-- | Expand a complete normalized trace page.  Blob digests, internal turn ids
-- and node ids never cross this boundary.
expandTurnTrace ::
  (WithConnection :> es, IOE :> es) =>
  ConversationScope ->
  Maybe UTCTime ->
  TurnOrdinal ->
  Maybe Int64 ->
  Int ->
  Eff es (Maybe Value)
expandTurnTrace scope cleared ordinal after limit = do
  targets <- case cleared of
    Nothing -> query turnSql (conversationStorageId scope, ordinal)
    Just watermark -> query (turnSql <> " AND t.started_at > ?") (conversationStorageId scope, ordinal, watermark)
  case targets :: [(AgentTurnId, Text, Maybe Text, UTCTime, Maybe UTCTime, Int64, Int64, Int64)] of
    [(turnId, status, profile, started, finished, llmTurns, promptTokens, completionTokens)] -> do
      let cursor = max 0 (fromMaybe 0 after)
          bounded = max 1 (min 100 limit)
      rows <-
        query
          "SELECT execution_ordinal, event_kind, state, tool_ref, schema_version, schema_hash, \
          \       normalized_input, effect_labels, retry_class, failure_code, failure_detail, \
          \       result_inline, result_preview, (result_blob_sha256 IS NOT NULL), result_size_bytes, \
          \       observed_manifest, started_at, finished_at \
          \FROM execution_journal WHERE turn_id=? AND execution_ordinal>? \
          \ORDER BY execution_ordinal LIMIT ?"
          (turnId, cursor, bounded + 1)
      outputs <- loadOutputs turnId
      let page = take bounded (rows :: [JournalTraceRow])
          hasMore = length rows > bounded
          nextCursor = if hasMore then journalOrdinal (last page) else Nothing
      pure . Just $
        object
          [ "handle" .= turnHandleText ordinal,
            "status" .= status,
            "profile" .= profile,
            "started_at" .= started,
            "finished_at" .= finished,
            "usage" .= object ["llm_turns" .= llmTurns, "prompt_tokens" .= promptTokens, "completion_tokens" .= completionTokens],
            "journal" .= map journalValue page,
            "outputs" .= [object ["chunk" .= chunk, "message_id" .= messageId, "preview" .= preview] | (chunk, messageId, preview) <- outputs],
            "has_more" .= hasMore,
            "next_after_cursor" .= nextCursor
          ]
    [] -> pure Nothing
    _ -> error "expandTurnTrace: duplicate scoped ordinal"
  where
    turnSql =
      "SELECT t.turn_id, t.status, t.profile, t.started_at, t.finished_at, t.llm_turns, \
      \       t.prompt_tokens, t.completion_tokens \
      \FROM conversations c JOIN agent_turns t USING (conversation_id) \
      \WHERE c.legacy_group_id=? AND t.turn_ordinal=?"

data TargetDigestRow = TargetDigestRow
  { tdrOrdinal :: !TurnOrdinal,
    tdrStatus :: !Text,
    tdrProfile :: !(Maybe Text),
    tdrStartedAt :: !UTCTime,
    tdrFinishedAt :: !(Maybe UTCTime),
    tdrToolCount :: !Int64,
    tdrSandboxes :: !Text,
    tdrOutputId :: !(Maybe Int64),
    tdrOutputLine :: !(Maybe Text),
    tdrPromptMajor :: !Int,
    tdrCatalogFingerprint :: !(Maybe Text),
    tdrFinishedIngestSeq :: !Int64
  }

instance FromRow TargetDigestRow where
  fromRow =
    TargetDigestRow <$> field <*> field <*> field <*> field <*> field <*> field
      <*> field <*> field <*> field <*> field <*> field <*> field

targetTurnDigest :: TargetDigestRow -> TurnDigest
targetTurnDigest row =
  turnDigestFromRow
    ( row.tdrOrdinal,
      row.tdrStatus,
      row.tdrProfile,
      row.tdrStartedAt,
      row.tdrFinishedAt,
      row.tdrToolCount,
      row.tdrSandboxes,
      row.tdrOutputId,
      row.tdrOutputLine
    )

data JournalTraceRow = JournalTraceRow
  { jtrOrdinal :: !Int64,
    jtrKind :: !Text,
    jtrState :: !Text,
    jtrToolRef :: !(Maybe Text),
    jtrSchemaVersion :: !(Maybe Int),
    jtrSchemaHash :: !(Maybe Text),
    jtrInput :: !(Maybe Value),
    jtrEffects :: !Value,
    jtrRetryClass :: !(Maybe Text),
    jtrFailureCode :: !(Maybe Text),
    jtrFailureDetail :: !(Maybe Text),
    jtrResultInline :: !(Maybe Value),
    jtrResultPreview :: !(Maybe Text),
    jtrSpilled :: !Bool,
    jtrResultSize :: !(Maybe Int64),
    jtrObserved :: !(Maybe Value),
    jtrStartedAt :: !UTCTime,
    jtrFinishedAt :: !(Maybe UTCTime)
  }

instance FromRow JournalTraceRow where
  fromRow =
    JournalTraceRow <$> field <*> field <*> field <*> field <*> field <*> field
      <*> field <*> field <*> field <*> field <*> field <*> field <*> field
      <*> field <*> field <*> field <*> field <*> field

journalOrdinal :: JournalTraceRow -> Maybe Int64
journalOrdinal = Just . (.jtrOrdinal)

journalValue :: JournalTraceRow -> Value
journalValue row =
  object
    [ "execution" .= ("r" <> T.pack (show row.jtrOrdinal)),
      "kind" .= row.jtrKind,
      "state" .= row.jtrState,
      "tool" .= row.jtrToolRef,
      "schema_version" .= row.jtrSchemaVersion,
      "schema_hash" .= row.jtrSchemaHash,
      "arguments" .= row.jtrInput,
      "effects" .= row.jtrEffects,
      "retry_class" .= row.jtrRetryClass,
      "failure" .= object ["code" .= row.jtrFailureCode, "detail" .= row.jtrFailureDetail],
      "result" .= row.jtrResultInline,
      "result_preview" .= row.jtrResultPreview,
      "result_spilled" .= row.jtrSpilled,
      "result_size_bytes" .= row.jtrResultSize,
      "observed_manifest" .= row.jtrObserved,
      "started_at" .= row.jtrStartedAt,
      "finished_at" .= row.jtrFinishedAt
    ]

-- | The fork-from chain behind a continuation target, newest first.
--
-- The walk is a recursive CTE over 'turn_edges' bounded by @depth@, and every
-- hop stays inside the caller's 'ConversationScope' — the seed is scoped and
-- the edge table's composite foreign keys make a cross-conversation hop
-- unrepresentable, so a chain can never smuggle another group's archive into
-- this prompt.  Only durable environment facts are returned; whether they
-- permit replay is "Max.Turn.Replay"'s pure decision.
--
-- 'rcTriggerLine' is left empty here.  Rendering it needs the prompt's
-- transcript grammar, so the caller fills it from the same scoped history
-- rows the digest tier reads.
replayChain ::
  (WithConnection :> es, IOE :> es) =>
  ConversationScope ->
  AgentTurnRef ->
  Int ->
  Eff es [ReplayCandidate]
replayChain scope target depth = do
  rows <-
    query
      "WITH RECURSIVE chain AS ( \
      \  SELECT t.turn_id, 0 AS hop \
      \  FROM conversations c JOIN agent_turns t USING (conversation_id) \
      \  WHERE c.legacy_group_id = ? AND t.turn_id = ? \
      \  UNION ALL \
      \  SELECT e.to_turn_id, chain.hop + 1 \
      \  FROM chain \
      \  JOIN turn_edges e ON e.from_turn_id = chain.turn_id AND e.edge_kind = 'fork-from' \
      \  JOIN conversations c ON c.conversation_id = e.conversation_id \
      \  WHERE c.legacy_group_id = ? AND chain.hop + 1 < ? \
      \) \
      \SELECT t.turn_id, t.turn_ordinal, t.profile, t.prompt_major, t.tool_catalog_fingerprint, \
      \       t.trace_archive_sha256, t.trace_archive_created_at, t.trace_archive_expires_at, \
      \       t.trigger_canonical_message_id, \
      \       COALESCE((SELECT array_agg(m.canonical_message_id ORDER BY m.turn_chunk_index) \
      \                 FROM messages m WHERE m.agent_turn_id = t.turn_id), '{}') \
      \FROM chain JOIN agent_turns t USING (turn_id) \
      \ORDER BY chain.hop"
      ( conversationStorageId scope,
        target.atrTurnId,
        conversationStorageId scope,
        max 1 depth
      )
  pure (map candidateFromRow rows)

type ReplayChainRow =
  ( AgentTurnId,
    TurnOrdinal,
    Maybe Text,
    Int,
    Maybe Text,
    Maybe Text,
    Maybe UTCTime,
    Maybe UTCTime,
    Maybe Int64,
    PGArray Int64
  )

candidateFromRow :: ReplayChainRow -> ReplayCandidate
candidateFromRow (turnId, ordinal, profile, promptMajor, catalog, sha, created, expires, trigger, outputs) =
  ReplayCandidate
    { rcTurn = AgentTurnRef turnId ordinal,
      rcProfile = profile,
      rcPromptMajor = promptMajor,
      rcCatalogFingerprint = catalog,
      rcArchiveSha = sha,
      rcArchiveCreatedAt = created,
      rcArchiveExpiresAt = expires,
      rcTriggerCanonicalId = trigger,
      rcTriggerLine = Nothing,
      rcOutputCanonicalIds = fromPGArray outputs
    }

-- | Logical eviction: only disposable archive references are removed.  The
-- journal/digest floor and content-addressed blob store remain untouched.
pruneTurnArchiveReferences ::
  (WithConnection :> es, IOE :> es) =>
  UTCTime ->
  Eff es Int64
pruneTurnArchiveReferences now =
  execute
    "WITH live_ranked AS ( \
    \  SELECT turn_id, \
    \         row_number() OVER (PARTITION BY conversation_id ORDER BY trace_archive_created_at DESC, turn_id DESC) AS recency \
    \  FROM agent_turns WHERE trace_archive_sha256 IS NOT NULL AND trace_archive_expires_at > ? \
    \), evicted AS ( \
    \  SELECT turn_id FROM agent_turns WHERE trace_archive_sha256 IS NOT NULL AND trace_archive_expires_at <= ? \
    \  UNION ALL SELECT turn_id FROM live_ranked WHERE recency > 50 \
    \) \
    \UPDATE agent_turns t SET trace_archive_sha256=NULL, trace_archive_size_bytes=NULL, \
    \  trace_archive_created_at=NULL, trace_archive_expires_at=NULL \
    \FROM evicted WHERE t.turn_id=evicted.turn_id"
    (now, now)

nonBlank :: Maybe Text -> Maybe Text
nonBlank = (>>= \text -> if T.null (T.strip text) then Nothing else Just text)
