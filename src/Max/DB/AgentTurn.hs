-- | E0's shared durability substrate: durable turn identity, the horizon-1
-- execution journal, scoped result envelopes, archive metadata, and restart
-- reconciliation.
--
-- This module deliberately exposes no ADR 005 continuation/read-side UI.
-- E0 records facts without changing model-visible behaviour.
module Max.DB.AgentTurn
  ( AgentTurnTerminal (..),
    JournalStart (..),
    JournalExecution (..),
    JournalFinish (..),
    JournalResultEnvelope (..),
    AgentTurnRecovery (..),
    ReclaimedTurns (..),
    startAgentTurn,
    markAgentTurnRunning,
    recordAgentTurnLlmRound,
    addAgentTurnUsage,
    finishAgentTurn,
    ensureAgentTurnCrashed,
    ensureAgentTurnRecoveryPending,
    reclaimInterruptedTurns,
    recoveryViewForTurn,
    nextAgentTurnOutputChunk,
    enrichSandboxJournalStart,
    startJournalExecution,
    recordModelNote,
    finishJournalExecution,
    markJournalOutcomeUnknown,
    lookupJournalResultEnvelope,
    resolveJournalResultValue,
  )
where

import Control.Monad (when)
import Data.Aeson (Value (..), eitherDecodeStrict', encode)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Int (Int64)
import Data.Maybe (fromMaybe)
import Data.Scientific (toBoundedInteger)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime)
import Database.PostgreSQL.Simple.ToField (ToField (..), toJSONField)
import Database.PostgreSQL.Simple.Types (Only (..))
import Effectful
import Effectful.PostgreSQL (WithConnection, execute, query)
import Max.ConversationScope (ConversationScope, conversationStorageId)
import Max.DB.Transaction (withTransaction)
import Max.Effects.Blob (Blob, blobRefFromSha256, blobRefSha256, putBlob, readBlob)
import Max.Monitor.Types (MonitorFireId (..))
import Max.Platform.Types (CanonicalMessageId (..), PrincipalId (..))
import Max.Turn.Types
import OneBot.Types (GroupId (..))

newtype Jsonb = Jsonb Value

instance ToField Jsonb where
  toField (Jsonb value) = toJSONField value

data AgentTurnTerminal
  = TurnSucceeded
  | TurnSilence
  | TurnFailed
  | TurnAborted
  | TurnCrashed
  deriving stock (Show, Eq)

terminalText :: AgentTurnTerminal -> Text
terminalText = \case
  TurnSucceeded -> "succeeded"
  TurnSilence -> "silence"
  TurnFailed -> "failed"
  TurnAborted -> "aborted"
  TurnCrashed -> "crashed"

data JournalStart = JournalStart
  { jsCallId :: !Text,
    jsToolRef :: !Text,
    jsSchemaVersion :: !Int,
    jsSchemaHash :: !Text,
    jsInput :: !Value,
    jsEffectLabels :: !Value,
    jsRetryClass :: !Text
  }
  deriving stock (Show, Eq)

data JournalExecution = JournalExecution
  { jeJournalId :: !Int64,
    jeTurn :: !AgentTurnRef,
    jeExecutionOrdinal :: !ExecutionOrdinal,
    jeNodeId :: !Text
  }
  deriving stock (Show, Eq)

data JournalFinish
  = JournalRejected !Text !Text
  | JournalFailed !Text !Text
  | JournalSucceeded !Value
  | JournalCommitted !Value
  | JournalOutcomeUnknown !Text !Text
  deriving stock (Show, Eq)

-- | Safe metadata returned by a scoped lookup.  The internal blob digest is
-- intentionally absent.  A later artifact resolver can read through the
-- journal row without turning possession of a digest into authority.
data JournalResultEnvelope = JournalResultEnvelope
  { jreTurn :: !AgentTurnRef,
    jreExecutionOrdinal :: !ExecutionOrdinal,
    jreState :: !Text,
    jreToolRef :: !(Maybe Text),
    jreInlineValue :: !(Maybe Value),
    jreSizeBytes :: !Int64,
    jrePreview :: !(Maybe Text),
    jreArtifactSpilled :: !Bool
  }
  deriving stock (Show, Eq)

data ReclaimedTurns = ReclaimedTurns
  { rrTurnsPendingResume :: !Int64,
    rrTurnsCrashed :: !Int64,
    rrExecutionsUnknown :: !Int64,
    rrRecoveries :: ![AgentTurnRecovery]
  }
  deriving stock (Show, Eq)

data AgentTurnRecovery = AgentTurnRecovery
  { atrRecoveryTurn :: !AgentTurnRef,
    atrRecoveryGroupId :: !GroupId,
    atrRecoveryTrigger :: !(Maybe CanonicalMessageId),
    atrRecoveryMonitorFire :: !(Maybe MonitorFireId)
  }
  deriving stock (Show, Eq)

-- | Allocate the persisted conversation-scoped ordinal at dispatch admission.
-- The conversation-row lock serializes concurrent turn creation without a
-- second mutable counter.
startAgentTurn ::
  (WithConnection :> es, IOE :> es) =>
  GroupId ->
  CanonicalMessageId ->
  PrincipalId ->
  Eff es AgentTurnRef
startAgentTurn (GroupId legacyGroup) (CanonicalMessageId trigger) (PrincipalId initiator) =
  withTransaction $ do
    conversationRows <-
      query
        "SELECT conversation_id FROM conversations WHERE legacy_group_id = ? FOR UPDATE"
        (Only legacyGroup)
    let conversation = exactlyOne "startAgentTurn conversation" (conversationRows :: [Only Int64])
    ordinalRows <-
      query
        "SELECT COALESCE(max(turn_ordinal), 0) + 1 FROM agent_turns WHERE conversation_id = ?"
        (Only conversation)
    let ordinal = exactlyOne "startAgentTurn ordinal" (ordinalRows :: [Only Int64])
    inserted <-
      query
        "INSERT INTO agent_turns \
        \ (conversation_id, turn_ordinal, trigger_canonical_message_id, initiator_principal_id, status) \
        \ VALUES (?, ?, ?, ?, 'starting') RETURNING turn_id"
        (conversation, ordinal, if trigger > 0 then Just trigger else Nothing, initiator)
    let turnId = exactlyOne "startAgentTurn id" (inserted :: [Only AgentTurnId])
    pure (AgentTurnRef turnId (TurnOrdinal ordinal))

markAgentTurnRunning ::
  (WithConnection :> es, IOE :> es) =>
  AgentTurnRef ->
  Text ->
  Eff es ()
markAgentTurnRunning ref profile = do
  _ <-
    execute
      "UPDATE agent_turns SET status = 'running', profile = ? \
      \ WHERE turn_id = ? AND status = ANY (ARRAY['starting'::text, 'recovery-pending'::text])"
      (profile, ref.atrTurnId)
  pure ()

-- | Checkpoint an attempted model round before crossing the provider
-- boundary.  Unlike token usage (known only from a response), this survives a
-- process death during the request and lets one recovered durable turn retain
-- the work count from every process incarnation.
recordAgentTurnLlmRound ::
  (WithConnection :> es, IOE :> es) =>
  AgentTurnId ->
  Eff es Bool
recordAgentTurnLlmRound turnId = do
  moved <-
    execute
      "UPDATE agent_turns SET llm_turns = llm_turns + 1 \
      \ WHERE turn_id = ? \
      \   AND status = ANY (ARRAY['starting'::text, 'running'::text, 'recovery-pending'::text])"
      (Only turnId)
  pure (moved > 0)

addAgentTurnUsage ::
  (WithConnection :> es, IOE :> es) =>
  AgentTurnId ->
  Int ->
  Int ->
  Maybe Int ->
  Eff es ()
addAgentTurnUsage turnId prompt completion cached = do
  _ <-
    execute
      "UPDATE agent_turns \
      \ SET prompt_tokens = prompt_tokens + ?, \
      \     completion_tokens = completion_tokens + ?, \
      \     cached_prompt_tokens = cached_prompt_tokens + ? \
      \ WHERE turn_id = ?"
      (max 0 prompt, max 0 completion, max 0 (fromMaybe 0 cached), turnId)
  pure ()

-- | Atomically publish the terminal checkpoint and the optional archive
-- reference.  The content-addressed blob is written before this call; a crash
-- between the two can leak only an unreferenced cache object.
finishAgentTurn ::
  (WithConnection :> es, IOE :> es) =>
  AgentTurnRef ->
  AgentTurnTerminal ->
  Int ->
  Maybe Text ->
  Maybe (Text, Int64, UTCTime) ->
  Eff es ()
finishAgentTurn ref terminal llmTurns abortReason archive = do
  withTransaction $ do
    let (archiveSha, archiveSize, archiveExpiry) = case archive of
          Nothing -> (Nothing, Nothing, Nothing)
          Just (sha, size, expires) -> (Just sha, Just size, Just expires)
    archiveConversation <- case archive of
      Nothing -> pure Nothing
      Just _ -> do
        -- Serialize archive publication per conversation.  Without this,
        -- two turns finishing together could each observe 49 live archives
        -- and commit a 51st row despite the LRU cap.
        rows <-
          query
            "SELECT c.conversation_id FROM conversations c \
            \JOIN agent_turns t USING (conversation_id) \
            \WHERE t.turn_id = ? FOR UPDATE OF c"
            (Only ref.atrTurnId)
        pure $ case rows :: [Only Int64] of
          [Only conversationId] -> Just conversationId
          _ -> error "finishAgentTurn: turn conversation not found"
    -- A cancellation can land after an effect returned but before its result
    -- update committed.  Close any such row in the same transaction as the
    -- terminal checkpoint so an aborted turn never strands state='started'.
    _ <-
      execute
        "UPDATE execution_journal j \
        \ SET state = 'outcome-unknown', finished_at = now(), \
        \     failure_code = COALESCE(failure_code, 'turn_terminal'), \
        \     failure_detail = COALESCE(failure_detail, 'turn ended before the effect outcome was durably recorded') \
        \ FROM agent_turns t \
        \ WHERE j.turn_id = t.turn_id AND j.turn_id = ? AND j.state = 'started' \
        \   AND t.status = ANY (ARRAY['starting'::text, 'running'::text, 'recovery-pending'::text])"
        (Only ref.atrTurnId)
    _ <-
      execute
        "UPDATE agent_turns \
        \ SET status = ?, finished_at = now(), llm_turns = GREATEST(llm_turns, ?), abort_reason = ?, \
        \     trace_archive_sha256 = ?, trace_archive_size_bytes = ?, \
        \     trace_archive_created_at = CASE WHEN ?::text IS NULL THEN NULL ELSE now() END, \
        \     trace_archive_expires_at = ? \
        \ WHERE turn_id = ? AND status = ANY (ARRAY['starting'::text, 'running'::text, 'recovery-pending'::text])"
        ( terminalText terminal,
          max 0 llmTurns,
          T.take 4000 <$> abortReason,
          archiveSha,
          archiveSize,
          archiveSha,
          archiveExpiry,
          ref.atrTurnId
        )
    case archiveConversation of
      Nothing -> pure ()
      Just conversationId -> do
        -- The stored expiry is the 14-day policy decided by the writer.  This
        -- transaction enforces both that TTL and the exact 50-turn live LRU
        -- cap continuously; boot maintenance remains a global safety sweep.
        _ <-
          execute
            "WITH live_ranked AS ( \
            \  SELECT turn_id, row_number() OVER (ORDER BY trace_archive_created_at DESC, turn_id DESC) AS recency \
            \  FROM agent_turns WHERE conversation_id = ? \
            \    AND trace_archive_sha256 IS NOT NULL AND trace_archive_expires_at > now() \
            \), evicted AS ( \
            \  SELECT turn_id FROM agent_turns WHERE conversation_id = ? \
            \    AND trace_archive_sha256 IS NOT NULL AND trace_archive_expires_at <= now() \
            \  UNION ALL SELECT turn_id FROM live_ranked WHERE recency > 50 \
            \) \
            \UPDATE agent_turns t SET trace_archive_sha256=NULL, trace_archive_size_bytes=NULL, \
            \  trace_archive_created_at=NULL, trace_archive_expires_at=NULL \
            \FROM evicted WHERE t.turn_id=evicted.turn_id"
            (conversationId, conversationId)
        pure ()
    pure ()

ensureAgentTurnCrashed ::
  (WithConnection :> es, IOE :> es) =>
  AgentTurnRef ->
  Text ->
  Eff es ()
ensureAgentTurnCrashed ref reason =
  finishAgentTurn ref TurnCrashed 0 (Just reason) Nothing

-- | Preserve an asynchronously unwound turn for the next boot.  Normal,
-- killed, and synchronously failed paths have already published a terminal
-- status, so this conditional update is a no-op for them.
ensureAgentTurnRecoveryPending ::
  (WithConnection :> es, IOE :> es) =>
  AgentTurnRef ->
  Text ->
  Eff es ()
ensureAgentTurnRecoveryPending ref reason = withTransaction $ do
  _ <-
    execute
      "UPDATE execution_journal j \
      \ SET state = 'outcome-unknown', finished_at = now(), \
      \     failure_code = COALESCE(failure_code, 'turn_suspended'), \
      \     failure_detail = COALESCE(failure_detail, 'turn suspended before the effect outcome was durably recorded') \
      \ FROM agent_turns t \
      \ WHERE j.turn_id = t.turn_id AND j.turn_id = ? AND j.state = 'started' \
      \   AND t.status = ANY (ARRAY['starting'::text, 'running'::text, 'recovery-pending'::text])"
      (Only ref.atrTurnId)
  _ <-
    execute
      "UPDATE agent_turns \
      \ SET status = 'recovery-pending', recovery_owner = NULL, recovery_claimed_at = NULL, \
      \     abort_reason = ? \
      \ WHERE turn_id = ? \
      \   AND status = ANY (ARRAY['starting'::text, 'running'::text, 'recovery-pending'::text])"
      (T.take 4000 reason, ref.atrTurnId)
  pure ()

-- | Conservatively reclaim rows left in-flight by a prior process.  A started
-- effect may have crossed its external boundary, so it becomes
-- outcome-unknown and is never silently invoked again.
reclaimInterruptedTurns ::
  (WithConnection :> es, IOE :> es) =>
  Text ->
  Eff es ReclaimedTurns
reclaimInterruptedTurns recoveryOwner = withTransaction $ do
  executions <-
    execute
      "UPDATE execution_journal \
      \ SET state = 'outcome-unknown', finished_at = now(), \
      \     failure_code = COALESCE(failure_code, 'process_restart'), \
      \     failure_detail = COALESCE(failure_detail, '工具执行状态未知：服务重启') \
      \ WHERE state = 'started'"
      ()
  recoveryRows <-
    query
      "UPDATE agent_turns t \
      \ SET status = 'recovery-pending', recovery_owner = ?, recovery_claimed_at = now() \
      \ FROM conversations c \
      \ WHERE t.conversation_id = c.conversation_id \
      \   AND (t.trigger_canonical_message_id IS NOT NULL OR EXISTS ( \
      \     SELECT 1 FROM monitor_fires f WHERE f.admitted_turn_id=t.turn_id)) \
      \   AND (t.status = ANY (ARRAY['starting'::text, 'running'::text]) \
      \        OR (t.status = 'recovery-pending' AND t.recovery_owner IS DISTINCT FROM ?)) \
      \ RETURNING t.turn_id, t.turn_ordinal, c.legacy_group_id, t.trigger_canonical_message_id, \
      \   (SELECT f.fire_id FROM monitor_fires f WHERE f.admitted_turn_id=t.turn_id)"
      (recoveryOwner, recoveryOwner)
  let recoveries =
        [ AgentTurnRecovery
            { atrRecoveryTurn = AgentTurnRef turnId (TurnOrdinal ordinal),
              atrRecoveryGroupId = GroupId groupId,
              atrRecoveryTrigger = CanonicalMessageId <$> trigger,
              atrRecoveryMonitorFire = MonitorFireId <$> monitorFire
            }
        | (turnId, ordinal, groupId, trigger, monitorFire) <-
            (recoveryRows :: [(AgentTurnId, Int64, Int64, Maybe Int64, Maybe Int64)])
        ]
  crashed <-
    execute
      "UPDATE agent_turns \
      \ SET status = 'crashed', finished_at = now(), \
      \     abort_reason = COALESCE(abort_reason, 'process restarted while turn was in flight') \
      \ WHERE trigger_canonical_message_id IS NULL \
      \   AND NOT EXISTS (SELECT 1 FROM monitor_fires f WHERE f.admitted_turn_id=agent_turns.turn_id) \
      \   AND (status = ANY (ARRAY['starting'::text, 'running'::text]) \
      \        OR (status = 'recovery-pending' AND recovery_owner IS DISTINCT FROM ?))"
      (Only recoveryOwner)
  pure
    ReclaimedTurns
      { rrTurnsPendingResume = fromIntegral (length recoveries),
        rrTurnsCrashed = crashed,
        rrExecutionsUnknown = executions,
        rrRecoveries = recoveries
      }

-- | Deterministic, bounded facts injected into the fresh LLM round after a
-- process restart.  This is a horizon-1 hole view, not ADR 005's general
-- continuity read side: it is host-selected for exactly the turn being
-- recovered and exposes no blob addresses or ambient handles.
recoveryViewForTurn ::
  (WithConnection :> es, IOE :> es) =>
  AgentTurnRef ->
  Eff es Text
recoveryViewForTurn turn = do
  journalRows <-
    query
      "SELECT execution_ordinal, event_kind, state, tool_ref, \
      \       left(COALESCE(normalized_input::text, ''), 1200), \
      \       left(COALESCE(result_preview, ''), 1200), \
      \       left(COALESCE(observed_manifest::text, ''), 1200), \
      \       left(COALESCE(failure_detail, ''), 1200) \
      \ FROM execution_journal WHERE turn_id = ? \
      \ ORDER BY execution_ordinal LIMIT 200"
      (Only turn.atrTurnId)
  outputRows <-
    query
      "SELECT turn_chunk_index, canonical_message_id, left(rendered_text, 1200) \
      \ FROM messages WHERE agent_turn_id = ? \
      \ ORDER BY turn_chunk_index LIMIT 100"
      (Only turn.atrTurnId)
  let header =
        [ "[服务重启恢复视图]",
          "以下是本 turn 已经持久化的事实。继续原任务，但不要自动重复已提交发送或状态未知的副作用。"
        ]
      outputs =
        [ "- 已提交可见输出 chunk=" <> tshow chunk <> " message=#" <> tshow message <> summary text
        | (chunk, message, text) <- (outputRows :: [(Int, Int64, Text)])
        ]
      events = map renderRecoveryEvent (journalRows :: [(Int64, Text, Text, Maybe Text, Text, Text, Text, Text)])
      footer =
        [ "- 对 outcome-unknown：不要假定失败，也不要静默重试；先读取当前状态、采用幂等检查，或明确询问用户。",
          "[恢复视图结束]"
        ]
  pure (T.take 24000 (T.unlines (header <> outputs <> events <> footer)))
  where
    summary text
      | T.null (T.strip text) = ""
      | otherwise = " preview=" <> quoted text

-- | The canonical ledger is the source of truth for already-published turn
-- output.  Recovery seeds its process-local allocator after the greatest
-- committed chunk so it can neither reuse nor collide with an old identity.
nextAgentTurnOutputChunk ::
  (WithConnection :> es, IOE :> es) =>
  AgentTurnId ->
  Eff es Int
nextAgentTurnOutputChunk turnId = do
  rows <-
    query
      "SELECT COALESCE(max(m.turn_chunk_index)::bigint, -1) + 1 \
      \ FROM agent_turns t \
      \ LEFT JOIN messages m ON m.agent_turn_id = t.turn_id \
      \ WHERE t.turn_id = ? GROUP BY t.turn_id"
      (Only turnId)
  let next = exactlyOne "nextAgentTurnOutputChunk" (rows :: [Only Int64])
  if next <= fromIntegral (maxBound :: Int)
    then pure (fromIntegral next)
    else error "nextAgentTurnOutputChunk: chunk index overflow"

renderRecoveryEvent :: (Int64, Text, Text, Maybe Text, Text, Text, Text, Text) -> Text
renderRecoveryEvent (ordinal, eventKind, state, toolRef, input, result, observation, failure) =
  "- execution="
    <> tshow ordinal
    <> " kind="
    <> eventKind
    <> maybe "" (" tool=" <>) toolRef
    <> " state="
    <> state
    <> field " input=" input
    <> field " result=" result
    <> field " observation=" observation
    <> field " failure=" failure
    <> if state == "outcome-unknown" then " [工具执行状态未知：服务重启]" else ""
  where
    field label value
      | T.null (T.strip value) = ""
      | otherwise = label <> quoted value

quoted :: Text -> Text
quoted = ("「" <>) . (<> "」") . T.unwords . T.words

tshow :: (Show a) => a -> Text
tshow = T.pack . show

-- | Add host-observed sandbox network mode to the immutable started row.  The
-- model chooses a sandbox handle but cannot choose or forge this value.
enrichSandboxJournalStart ::
  (WithConnection :> es, IOE :> es) =>
  GroupId ->
  JournalStart ->
  Eff es JournalStart
enrichSandboxJournalStart (GroupId groupId) start
  | start.jsToolRef /= "sandbox_exec" = pure start
  | Object fields <- start.jsInput,
    Just (String sandboxId) <- KeyMap.lookup "sandbox_id" fields = do
      let normalized =
            KeyMap.insert
              "packages"
              (fromMaybe (Array mempty) (KeyMap.lookup "packages" fields))
              ( KeyMap.insert
                  "timeout_seconds"
                  (fromMaybe (Number 30) (KeyMap.lookup "timeout_seconds" fields))
                  fields
              )
      rows <-
        query
          "SELECT sb.network_mode FROM sandboxes sb \
          \ JOIN conversations c USING (conversation_id) \
          \ WHERE c.legacy_group_id = ? AND sb.sandbox_handle = ? \
          \   AND sb.status <> 'destroyed'"
          (groupId, sandboxId)
      pure $ case rows :: [Only Text] of
        [Only network] ->
          start
            { jsInput = Object (KeyMap.insert "_max_host_network_mode" (String network) normalized)
            }
        _ -> start {jsInput = Object normalized}
  | otherwise = pure start

startJournalExecution ::
  (WithConnection :> es, IOE :> es) =>
  AgentTurnRef ->
  JournalStart ->
  Eff es JournalExecution
startJournalExecution turn start = withTransaction $ do
  locked <- query "SELECT turn_id FROM agent_turns WHERE turn_id = ? FOR UPDATE" (Only turn.atrTurnId)
  case locked :: [Only AgentTurnId] of
    [_] -> pure ()
    _ -> error "startJournalExecution: turn not found"
  ordinalRows <-
    query
      "SELECT COALESCE(max(execution_ordinal), 0) + 1 FROM execution_journal WHERE turn_id = ?"
      (Only turn.atrTurnId)
  let ordinal = exactlyOne "startJournalExecution ordinal" (ordinalRows :: [Only Int64])
  let executionOrdinal = ExecutionOrdinal ordinal
      AgentTurnId turnIdRaw = turn.atrTurnId
      nodeId = "turn:" <> T.pack (show turnIdRaw) <> ":" <> T.pack (show ordinal)
  inserted <-
    query
      "INSERT INTO execution_journal \
      \ (turn_id, execution_ordinal, node_id, event_kind, state, call_id, tool_ref, \
      \  schema_version, schema_hash, normalized_input, effect_labels, retry_class) \
      \ VALUES (?, ?, ?, 'tool_call', 'started', ?, ?, ?, ?, ?, ?, ?) \
      \ RETURNING journal_id"
      ( turn.atrTurnId,
        ordinal,
        nodeId,
        start.jsCallId,
        start.jsToolRef,
        start.jsSchemaVersion,
        start.jsSchemaHash,
        Jsonb start.jsInput,
        Jsonb start.jsEffectLabels,
        start.jsRetryClass
      )
  let journalId = exactlyOne "startJournalExecution id" (inserted :: [Only Int64])
  pure
    JournalExecution
      { jeJournalId = journalId,
        jeTurn = turn,
        jeExecutionOrdinal = executionOrdinal,
        jeNodeId = nodeId
      }

-- | Plain-text in-band narration is a zero-authority fact row.  It has an
-- ordinal for total ordering but no result handle.
recordModelNote ::
  (WithConnection :> es, IOE :> es) =>
  AgentTurnRef ->
  Text ->
  Eff es ()
recordModelNote turn note
  | T.null (T.strip note) = pure ()
  | otherwise = withTransaction $ do
      locked <- query "SELECT turn_id FROM agent_turns WHERE turn_id = ? FOR UPDATE" (Only turn.atrTurnId)
      case locked :: [Only AgentTurnId] of
        [_] -> pure ()
        _ -> error "recordModelNote: turn not found"
      ordinalRows <-
        query
          "SELECT COALESCE(max(execution_ordinal), 0) + 1 FROM execution_journal WHERE turn_id = ?"
          (Only turn.atrTurnId)
      let ordinal = exactlyOne "recordModelNote ordinal" (ordinalRows :: [Only Int64])
      let AgentTurnId turnIdRaw = turn.atrTurnId
          nodeId = "turn:" <> T.pack (show turnIdRaw) <> ":" <> T.pack (show ordinal)
          bounded = T.take 8000 (T.strip note)
          size = fromIntegral (BS.length (TE.encodeUtf8 bounded)) :: Int64
      count <-
        execute
          "INSERT INTO execution_journal \
          \ (turn_id, execution_ordinal, node_id, event_kind, state, effect_labels, \
          \  result_inline, result_size_bytes, result_preview, finished_at) \
          \ VALUES (?, ?, ?, 'model_note', 'succeeded', '[]'::jsonb, ?, ?, ?, now())"
          (turn.atrTurnId, ordinal, nodeId, Jsonb (String bounded), size, bounded)
      when (count /= 1) (error "recordModelNote: insert did not affect one row")

finishJournalExecution ::
  (Blob :> es, WithConnection :> es, IOE :> es) =>
  JournalExecution ->
  JournalFinish ->
  Eff es ()
finishJournalExecution execution finish = do
  storage <- case stripJournalPrivateMetadata <$> finishValue finish of
    Nothing -> pure (Nothing, Nothing, Nothing, Nothing)
    Just value -> do
      let bytes = LBS.toStrict (encode value)
          size = fromIntegral (BS.length bytes) :: Int64
          preview = previewValue value
      if size <= inlineResultLimit
        then pure (Just (Jsonb value), Nothing, Just size, Just preview)
        else do
          blob <- putBlob bytes
          pure (Nothing, Just (blobRefSha256 blob), Just size, Just preview)
  let (inlineValue, blobSha, resultSize, resultPreview) = storage
      (state, failureCode, failureDetail) = finishFault finish
      outputCanonical = finishOutputCanonical finish
      observedManifest = finishObservedManifest finish
  changed <-
    execute
      "UPDATE execution_journal \
      \ SET state = ?, failure_code = ?, failure_detail = ?, result_inline = ?, \
      \     result_blob_sha256 = ?, result_size_bytes = ?, result_preview = ?, \
      \     observed_manifest = ?, output_canonical_message_id = ?, finished_at = now() \
      \ WHERE journal_id = ? AND turn_id = ? AND state = 'started'"
      ( state,
        failureCode,
        T.take 4000 <$> failureDetail,
        inlineValue,
        blobSha,
        resultSize,
        resultPreview,
        Jsonb <$> observedManifest,
        outputCanonical,
        execution.jeJournalId,
        execution.jeTurn.atrTurnId
      )
  when (changed /= 1) (error "finishJournalExecution: journal row was not started")

markJournalOutcomeUnknown ::
  (WithConnection :> es, IOE :> es) =>
  JournalExecution ->
  Text ->
  Eff es ()
markJournalOutcomeUnknown execution detail = do
  _ <-
    execute
      "UPDATE execution_journal \
      \ SET state = 'outcome-unknown', failure_code = 'interrupted', \
      \     failure_detail = ?, finished_at = now() \
      \ WHERE journal_id = ? AND turn_id = ? AND state = 'started'"
      (T.take 4000 detail, execution.jeJournalId, execution.jeTurn.atrTurnId)
  pure ()

finishValue :: JournalFinish -> Maybe Value
finishValue = \case
  JournalSucceeded value -> Just value
  JournalCommitted value -> Just value
  _ -> Nothing

finishOutputCanonical :: JournalFinish -> Maybe Int64
finishOutputCanonical finish = do
  Object fields <- finishValue finish
  Number raw <- KeyMap.lookup "_max_journal_canonical_message_id" fields
  toBoundedInteger raw

finishObservedManifest :: JournalFinish -> Maybe Value
finishObservedManifest finish = do
  Object fields <- finishValue finish
  value@(Object _) <- KeyMap.lookup "_max_journal_observed_manifest" fields
  pure value

stripJournalPrivateMetadata :: Value -> Value
stripJournalPrivateMetadata (Object fields) =
  Object
    ( KeyMap.delete "_max_journal_canonical_message_id" $
        KeyMap.delete "_max_journal_observed_manifest" fields
    )
stripJournalPrivateMetadata value = value

finishFault :: JournalFinish -> (Text, Maybe Text, Maybe Text)
finishFault = \case
  JournalRejected code detail -> ("rejected", Just code, Just detail)
  JournalFailed code detail -> ("failed", Just code, Just detail)
  JournalSucceeded _ -> ("succeeded", Nothing, Nothing)
  JournalCommitted _ -> ("committed", Nothing, Nothing)
  JournalOutcomeUnknown code detail -> ("outcome-unknown", Just code, Just detail)

inlineResultLimit :: Int64
inlineResultLimit = 16 * 1024

previewValue :: Value -> Text
previewValue = T.take 1000 . T.unwords . T.words . TE.decodeUtf8 . LBS.toStrict . encode

-- | Resolve only through the conversation-scoped alternate key.  Rows from a
-- different conversation are indistinguishable from missing rows, and the
-- internal blob address never crosses this boundary.
lookupJournalResultEnvelope ::
  (WithConnection :> es, IOE :> es) =>
  ConversationScope ->
  TurnOrdinal ->
  ExecutionOrdinal ->
  Eff es (Maybe JournalResultEnvelope)
lookupJournalResultEnvelope scope turnOrdinal executionOrdinal = do
  rows <-
    query
      "SELECT t.turn_id, j.state, j.tool_ref, j.result_inline, j.result_size_bytes, \
      \       j.result_preview, (j.result_blob_sha256 IS NOT NULL) \
      \ FROM conversations c \
      \ JOIN agent_turns t USING (conversation_id) \
      \ JOIN execution_journal j ON j.turn_id = t.turn_id \
      \ WHERE c.legacy_group_id = ? AND t.turn_ordinal = ? AND j.execution_ordinal = ? \
      \   AND j.event_kind = 'tool_call' AND j.result_size_bytes IS NOT NULL"
      (conversationStorageId scope, turnOrdinal, executionOrdinal)
  pure $ case rows :: [(AgentTurnId, Text, Maybe Text, Maybe Value, Int64, Maybe Text, Bool)] of
    [(turnId, state, toolRef, inlineValue, size, preview, spilled)] ->
      Just
        JournalResultEnvelope
          { jreTurn = AgentTurnRef turnId turnOrdinal,
            jreExecutionOrdinal = executionOrdinal,
            jreState = state,
            jreToolRef = toolRef,
            jreInlineValue = inlineValue,
            jreSizeBytes = size,
            jrePreview = preview,
            jreArtifactSpilled = spilled
          }
    _ -> Nothing

-- | Resolve a model-facing result handle through conversation scope and the
-- current !clear boundary. The blob digest never leaves this function.
resolveJournalResultValue ::
  (Blob :> es, WithConnection :> es, IOE :> es) =>
  ConversationScope ->
  Maybe UTCTime ->
  Text ->
  Eff es (Maybe Value)
resolveJournalResultValue scope cleared raw = case parseTurnHandle raw of
  Just (ParsedTurnResult turnOrdinal executionOrdinal) -> do
    rows <-
      query
        "SELECT j.result_inline, j.result_blob_sha256 \
        \ FROM conversations c \
        \ JOIN agent_turns t USING (conversation_id) \
        \ JOIN execution_journal j ON j.turn_id = t.turn_id \
        \ WHERE c.legacy_group_id = ? AND t.turn_ordinal = ? AND j.execution_ordinal = ? \
        \   AND j.event_kind = 'tool_call' \
        \   AND j.state = ANY (ARRAY['succeeded'::text, 'committed'::text]) \
        \   AND (?::timestamptz IS NULL OR t.started_at >= ?)"
        (conversationStorageId scope, turnOrdinal, executionOrdinal, cleared, cleared)
    case rows :: [(Maybe Value, Maybe Text)] of
      [(Just value, Nothing)] -> pure (Just value)
      [(Nothing, Just sha)] -> case blobRefFromSha256 sha of
        Nothing -> pure Nothing
        Just ref -> do
          bytes <- readBlob ref
          pure (either (const Nothing) Just (eitherDecodeStrict' bytes))
      _ -> pure Nothing
  _ -> pure Nothing

exactlyOne :: Text -> [Only a] -> a
exactlyOne _ [Only value] = value
exactlyOne label rows = error (T.unpack label <> ": expected one row, got " <> show (length rows))
