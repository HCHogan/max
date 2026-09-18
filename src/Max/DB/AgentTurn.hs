-- | Turn identities, effect diagnostics and scoped results. Restart ends
-- interrupted foreground work and preserves uncertain effects for inspection.
module Max.DB.AgentTurn
  ( AgentTurnTerminal (..),
    JournalStart (..),
    JournalExecution (..),
    JournalFinish (..),
    JournalResultEnvelope (..),
    ReclaimedTurns (..),
    startAgentTurn,
    markAgentTurnRunning,
    recordAgentTurnLlmRound,
    addAgentTurnUsage,
    finishAgentTurn,
    ensureAgentTurnCrashed,
    reclaimInterruptedTurns,
    readSkillLoads,
    readWorkingContext,
    writeWorkingContext,
    enrichSandboxJournalStart,
    startJournalExecution,
    recordModelNote,
    finishJournalExecution,
    markJournalOutcomeUnknown,
    lookupJournalResultEnvelope,
    resolveJournalResultValue,
    expandJournalResult,
  )
where

import Control.Monad (forM_, when)
import Data.Aeson (Value (..), eitherDecodeStrict', encode, object, (.=))
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
import Max.DB.Task.Settlement (SettlementOutcome (..), settleTurn)
import Max.DB.Transaction (withTransaction)
import Max.Effects.Blob (Blob, blobRefFromSha256, blobRefSha256, putBlob, readBlob)
import Max.Execution.Types (JournalExecution (..), JournalFinish (..), JournalStart (..))
import Max.Platform.Types (CanonicalMessageId (..), PrincipalId (..))
import Max.Tool.Bundles (SkillLoad)
import Max.Turn.Types
import OneBot.Types (GroupId (..))

newtype Jsonb = Jsonb Value

instance ToField Jsonb where
  toField (Jsonb value) = toJSONField value

data AgentTurnTerminal
  = TurnSucceeded
  | TurnSilence
  | TurnFailed
  | TurnCancelled
  | TurnAborted
  | TurnCrashed
  deriving stock (Show, Eq)

terminalText :: AgentTurnTerminal -> Text
terminalText = \case
  TurnSucceeded -> "succeeded"
  TurnSilence -> "silence"
  TurnFailed -> "failed"
  TurnCancelled -> "aborted"
  TurnAborted -> "aborted"
  TurnCrashed -> "crashed"

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
  { rrTurnsCrashed :: !Int64,
    rrExecutionsUnknown :: !Int64
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

-- | Record completion and settle task/publication state in one transaction.
finishAgentTurn ::
  (WithConnection :> es, IOE :> es) =>
  AgentTurnRef ->
  AgentTurnTerminal ->
  Int ->
  Maybe Text ->
  Eff es ()
finishAgentTurn ref terminal llmTurns abortReason = do
  withTransaction $ do
    locked <- query "SELECT c.conversation_id FROM conversations c JOIN agent_turns t USING(conversation_id) WHERE t.turn_id=? FOR UPDATE OF c" (Only ref.atrTurnId)
    when (null (locked :: [Only Int64])) (error "finishAgentTurn: conversation missing")
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
    settled <-
      query
        "UPDATE agent_turns t \
        \ SET status = ?, finished_at = now(), \
        \     finished_ingest_seq = COALESCE((SELECT max(m.ingest_seq) FROM messages m WHERE m.conversation_id=t.conversation_id), 0), \
        \     llm_turns = GREATEST(llm_turns, ?), abort_reason = ? \
        \ WHERE turn_id = ? AND status = ANY (ARRAY['starting'::text, 'running'::text, 'recovery-pending'::text]) RETURNING turn_id"
        ( terminalText terminal,
          max 0 llmTurns,
          T.take 4000 <$> abortReason,
          ref.atrTurnId
        )
    let outcome = case terminal of
          TurnSucceeded -> SettlementSucceeded
          TurnSilence -> SettlementSucceeded
          TurnCancelled -> SettlementCancelled
          _ -> SettlementFailed
    forM_ (settled :: [Only AgentTurnId]) $ \(Only turn) -> settleTurn turn outcome abortReason

ensureAgentTurnCrashed ::
  (WithConnection :> es, IOE :> es) =>
  AgentTurnRef ->
  Text ->
  Eff es ()
ensureAgentTurnCrashed ref reason =
  finishAgentTurn ref TurnCrashed 0 (Just reason)

-- | Conservatively reclaim rows left in-flight by a prior process.  A started
-- effect may have crossed its external boundary, so it becomes
-- outcome-unknown and is never silently invoked again.
reclaimInterruptedTurns ::
  (WithConnection :> es, IOE :> es) =>
  Eff es ReclaimedTurns
reclaimInterruptedTurns = withTransaction $ do
  -- Recovery uses the same conversation-before-turn/journal order as normal
  -- settlement. Lock only conversations with recoverable or unknown work.
  (_ :: [Only Int64]) <-
    query
      "SELECT c.conversation_id FROM conversations c WHERE EXISTS(SELECT 1 FROM agent_turns t WHERE t.conversation_id=c.conversation_id AND t.status IN ('starting','running','recovery-pending'))\
      \ OR EXISTS(SELECT 1 FROM agent_turns t JOIN execution_journal j USING(turn_id) WHERE t.conversation_id=c.conversation_id AND j.state='started')\
      \ ORDER BY c.conversation_id FOR UPDATE"
      ()
  executions <-
    execute
      "UPDATE execution_journal \
      \ SET state = 'outcome-unknown', finished_at = now(), \
      \     failure_code = COALESCE(failure_code, 'process_restart'), \
      \     failure_detail = COALESCE(failure_detail, '工具执行状态未知：服务重启') \
      \ WHERE state = 'started'"
      ()
  crashed <-
    query
      "UPDATE agent_turns t \
      \ SET status = 'crashed', finished_at = now(), \
      \     finished_ingest_seq = COALESCE((SELECT max(m.ingest_seq) FROM messages m WHERE m.conversation_id=t.conversation_id), 0), \
      \     abort_reason = COALESCE(abort_reason, 'process restarted while turn was in flight') \
      \ WHERE true \
      \   AND NOT EXISTS (SELECT 1 FROM task_attempts task WHERE task.turn_id=t.turn_id) \
      \   AND status IN ('starting','running','recovery-pending') RETURNING turn_id,abort_reason"
      ()
  forM_ (crashed :: [(AgentTurnId, Maybe Text)]) $ \(turn, reason) -> settleTurn turn SettlementFailed reason
  pure (ReclaimedTurns (fromIntegral (length crashed)) executions)

-- | Successful skill loads remain available to the current task attempt.
readSkillLoads :: (WithConnection :> es, IOE :> es) => AgentTurnRef -> Eff es [SkillLoad]
readSkillLoads turn = do
  rows <-
    query
      "SELECT (j.observed_manifest->'skill_loads')::text FROM execution_journal j \
      \ WHERE j.tool_ref='use_skill' AND j.state IN ('succeeded','committed') \
      \ AND jsonb_typeof(j.observed_manifest->'skill_loads')='array' AND \
      \ (j.turn_id=? OR j.turn_id IN (SELECT previous.turn_id FROM task_attempts previous \
      \ JOIN task_attempts current ON previous.task_id=current.task_id AND previous.revision=current.revision \
      \ WHERE current.turn_id=? AND previous.attempt<=current.attempt)) \
      \ ORDER BY j.turn_id,j.execution_ordinal"
      (turn.atrTurnId, turn.atrTurnId)
  concat <$> traverse decode (rows :: [Only Text])
  where
    decode (Only value) = either (error . ("invalid durable skill receipt: " <>)) pure (eitherDecodeStrict' (TE.encodeUtf8 value))

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

-- The assembly's admission fence and this insert share one transaction.
writeWorkingContext :: (WithConnection :> es, IOE :> es) => AgentTurnRef -> Text -> Int -> Int -> Eff es ()
writeWorkingContext turn summary tokens limit = do
  _ <-
    execute
      "INSERT INTO turn_working_context(turn_id,summary,input_tokens,input_limit) VALUES (?,?,?,?)"
      (turn.atrTurnId, T.take 8000 summary, max 0 tokens, max 0 limit)
  pure ()

readWorkingContext :: (WithConnection :> es, IOE :> es) => AgentTurnRef -> Eff es Text
readWorkingContext turn = do
  rows <-
    query
      "SELECT w.summary FROM turn_working_context w WHERE w.turn_id=? OR w.turn_id IN \
      \(SELECT previous.turn_id FROM task_attempts previous JOIN task_attempts current \
      \ ON previous.task_id=current.task_id AND previous.revision=current.revision \
      \ WHERE current.turn_id=? AND previous.attempt<=current.attempt) ORDER BY w.checkpoint_id DESC LIMIT 1"
      (turn.atrTurnId, turn.atrTurnId)
  pure $ case rows of [Only summary] -> summary; _ -> ""

-- | Recover one journal result without publishing blob paths or replaying an
-- effect. Provider call ids are local to a turn; ambiguous ids fail closed.
-- Character pagination also bounds large inline and spilled JSON results.
expandJournalResult ::
  (WithConnection :> es, Blob :> es, IOE :> es) =>
  ConversationScope -> Maybe UTCTime -> Text -> Maybe Text -> Maybe Int64 -> Int -> Eff es (Maybe Value)
expandJournalResult scope cleared handle callId after limit = case target of
  Nothing -> pure Nothing
  Just (ordinal, execution) -> do
    rows <-
      query
        "SELECT j.execution_ordinal,j.state,j.tool_ref,j.normalized_input,j.failure_detail,j.result_inline,j.result_blob_sha256 \
        \ FROM conversations c JOIN agent_turns t USING(conversation_id) JOIN execution_journal j ON j.turn_id=t.turn_id \
        \ WHERE c.legacy_group_id=? AND t.turn_ordinal=? AND j.event_kind='tool_call' \
        \ AND (?::timestamptz IS NULL OR t.started_at>?) \
        \ AND (?::bigint IS NULL OR j.execution_ordinal=?) AND (?::text IS NULL OR j.call_id=?) LIMIT 2"
        (conversationStorageId scope, ordinal, cleared, cleared, execution, execution, callId, callId)
    case rows :: [(ExecutionOrdinal, Text, Maybe Text, Maybe Value, Maybe Text, Maybe Value, Maybe Text)] of
      [(number, state, name, input, failure, inline, blob)] -> do
        value <- case (inline, blob >>= blobRefFromSha256) of
          (Just v, _) -> pure (Just v)
          (_, Just ref) -> either (const Nothing) Just . eitherDecodeStrict' <$> readBlob ref
          _ -> pure Nothing
        let payload =
              TE.decodeUtf8 . LBS.toStrict . encode $
                object
                  ["state" .= state, "tool" .= name, "input" .= input, "failure" .= failure, "result" .= value]
            cursor = fromIntegral (max 0 (min (fromIntegral (T.length payload)) (fromMaybe 0 after)))
            bounded = max 256 (min 12000 limit)
            part = T.take bounded (T.drop cursor payload)
            next = cursor + T.length part
        pure . Just $
          object
            [ "handle" .= resultHandleText ordinal number,
              "format" .= ("json_text" :: Text),
              "text" .= part,
              "has_more" .= (next < T.length payload),
              "next_after_cursor" .= (if next < T.length payload then Just next else Nothing)
            ]
      _ -> pure Nothing
  where
    target = case (parseTurnHandle handle, callId) of
      (Just (ParsedTurnResult ordinal execution), Nothing) -> Just (ordinal, Just execution)
      (Just (ParsedTurn ordinal), Just cid) | not (T.null cid) -> Just (ordinal, Nothing)
      _ -> Nothing
