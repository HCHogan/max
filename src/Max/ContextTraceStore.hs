-- |
-- Durable, body-free prompt-planning traces.  These rows explain token
-- allocation and materialization decisions without retaining another copy of
-- the rendered prompt.  They are operational projections and are bounded per
-- conversation.
module Max.ContextTraceStore
  ( ContextPlanTraceRow (..),
    recordContextPlanTrace,
    listContextPlanTraces,
  )
where

import Data.Aeson (ToJSON, Value, eitherDecodeStrict', encode, object, (.=))
import Data.ByteString.Lazy qualified as LBS
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime)
import Database.PostgreSQL.Simple.FromRow (FromRow (..), field)
import Effectful
import Effectful.PostgreSQL (WithConnection, execute, query)
import Max.Context (ContextBudget (..), ContextDecision (..), ContextTrace (..))
import Max.ConversationScope (ConversationScope, conversationStorageId)

data ContextPlanTraceRow = ContextPlanTraceRow
  { cptrId :: !Int64,
    cptrConversationId :: !Int64,
    cptrTriggerMessageId :: !Int64,
    cptrHistoryMode :: !Text,
    cptrPolicyVersion :: !Text,
    cptrMaterializationRevision :: !(Maybe Int64),
    cptrMaterializationReason :: !(Maybe Text),
    cptrEstimatedPromptTokens :: !Int,
    cptrPromptTokenLimit :: !Int,
    cptrMaxInputTokens :: !Int,
    cptrReservedOutputTokens :: !Int,
    cptrAttachmentReserve :: !Int,
    cptrToolRoundReserve :: !Int,
    cptrWithinBudget :: !Bool,
    cptrDecisions :: !Value,
    cptrCreatedAt :: !UTCTime
  }
  deriving stock (Show, Eq)

data StoredContextPlanTrace = StoredContextPlanTrace
  { storedId :: !Int64,
    storedConversationId :: !Int64,
    storedTriggerMessageId :: !Int64,
    storedHistoryMode :: !Text,
    storedPolicyVersion :: !Text,
    storedMaterializationRevision :: !(Maybe Int64),
    storedMaterializationReason :: !(Maybe Text),
    storedEstimatedPromptTokens :: !Int,
    storedPromptTokenLimit :: !Int,
    storedMaxInputTokens :: !Int,
    storedReservedOutputTokens :: !Int,
    storedAttachmentReserve :: !Int,
    storedToolRoundReserve :: !Int,
    storedWithinBudget :: !Bool,
    storedDecisions :: !Text,
    storedCreatedAt :: !UTCTime
  }

instance FromRow StoredContextPlanTrace where
  fromRow =
    StoredContextPlanTrace
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

-- | Append one trace, then retain only the newest bounded diagnostic history
-- for that conversation.  Failure is handled by the prompt caller so this
-- observability write can never prevent a reply.
recordContextPlanTrace ::
  (WithConnection :> es, IOE :> es) =>
  ConversationScope ->
  Int64 ->
  Text ->
  Text ->
  Maybe Int64 ->
  Maybe Text ->
  ContextBudget ->
  Int ->
  Bool ->
  [ContextTrace] ->
  Eff es ()
recordContextPlanTrace scope triggerMessageId historyMode policyVersion materializationRevision materializationReason budget estimated withinBudget decisions = do
  let conversationId = conversationStorageId scope
  _ <-
    execute
      "INSERT INTO context_plan_traces \
      \ (conversation_id, trigger_message_id, history_mode, policy_version, \
      \  materialization_revision, materialization_reason, estimated_prompt_tokens, \
      \  prompt_token_limit, max_input_tokens, reserved_output_tokens, \
      \  attachment_reserve, tool_round_reserve, within_budget, decisions) \
      \ VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?::jsonb)"
      ( conversationId,
        triggerMessageId,
        historyMode,
        policyVersion,
        materializationRevision,
        materializationReason,
        estimated,
        budget.cbPromptTokenLimit,
        budget.cbMaxInputTokens,
        budget.cbReservedOutputTokens,
        budget.cbAttachmentReserve,
        budget.cbToolRoundReserve,
        withinBudget,
        encodeText (map traceJson decisions)
      )
  _ <-
    execute
      "DELETE FROM context_plan_traces \
      \ WHERE conversation_id = ? AND id < COALESCE(( \
      \   SELECT id FROM context_plan_traces \
      \   WHERE conversation_id = ? ORDER BY id DESC OFFSET 199 LIMIT 1 \
      \ ), 0)"
      (conversationId, conversationId)
  pure ()

listContextPlanTraces ::
  (WithConnection :> es, IOE :> es) =>
  Maybe Int64 ->
  Int ->
  Eff es [ContextPlanTraceRow]
listContextPlanTraces conversationId requestedLimit = do
  rows <-
    query
      "SELECT id, conversation_id, trigger_message_id, history_mode, policy_version, \
      \       materialization_revision, materialization_reason, estimated_prompt_tokens, \
      \       prompt_token_limit, max_input_tokens, reserved_output_tokens, \
      \       attachment_reserve, tool_round_reserve, within_budget, decisions::text, created_at \
      \ FROM context_plan_traces \
      \ WHERE (?::bigint IS NULL OR conversation_id = ?) \
      \ ORDER BY id DESC LIMIT ?"
      (conversationId, conversationId, max 1 (min 200 requestedLimit))
  pure (map decodeRow (rows :: [StoredContextPlanTrace]))
  where
    decodeRow stored =
      ContextPlanTraceRow
          { cptrId = stored.storedId,
            cptrConversationId = stored.storedConversationId,
            cptrTriggerMessageId = stored.storedTriggerMessageId,
            cptrHistoryMode = stored.storedHistoryMode,
            cptrPolicyVersion = stored.storedPolicyVersion,
            cptrMaterializationRevision = stored.storedMaterializationRevision,
            cptrMaterializationReason = stored.storedMaterializationReason,
            cptrEstimatedPromptTokens = stored.storedEstimatedPromptTokens,
            cptrPromptTokenLimit = stored.storedPromptTokenLimit,
            cptrMaxInputTokens = stored.storedMaxInputTokens,
            cptrReservedOutputTokens = stored.storedReservedOutputTokens,
            cptrAttachmentReserve = stored.storedAttachmentReserve,
            cptrToolRoundReserve = stored.storedToolRoundReserve,
            cptrWithinBudget = stored.storedWithinBudget,
            cptrDecisions = either (const (object ["decode_error" .= True])) id (eitherDecodeValue stored.storedDecisions),
            cptrCreatedAt = stored.storedCreatedAt
          }

traceJson :: ContextTrace -> Value
traceJson trace =
  object
    [ "source" .= trace.ctSource,
      "estimated_tokens" .= trace.ctEstimatedTokens,
      "decision" .= decisionText trace.ctDecision,
      "reason" .= trace.ctReason
    ]

decisionText :: ContextDecision -> Text
decisionText = \case
  ContextIncluded -> "included"
  ContextDropped -> "dropped"
  ContextReserved -> "reserved"
  ContextOverBudget -> "over_budget"

encodeText :: (ToJSON a) => a -> Text
encodeText = TE.decodeUtf8 . LBS.toStrict . encode

eitherDecodeValue :: Text -> Either String Value
eitherDecodeValue = eitherDecodeStrict' . TE.encodeUtf8
