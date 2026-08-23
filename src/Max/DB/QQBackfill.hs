-- | Durable audit records for bounded QQ history recovery.  These rows are
-- evidence of what Max attempted and observed; they are deliberately not a
-- cursor and never claim that NapCat returned a complete offline interval.
module Max.DB.QQBackfill
  ( QQBackfillEndpoint (..),
    QQBackfillRunId,
    QQBackfillResult (..),
    listQQBackfillEndpoints,
    startQQBackfillRun,
    finishQQBackfillRun,
  )
where

import Data.Int (Int64)
import Data.Text (Text)
import Data.Time (UTCTime)
import Database.PostgreSQL.Simple.Types (Only (..))
import Effectful
import Effectful.PostgreSQL (WithConnection, execute, query)
import Max.Platform.Store (RegisteredEndpoint (..))
import Max.Platform.Types (ConversationId (..), EndpointId (..), PlatformAccountId (..))

data QQBackfillEndpoint = QQBackfillEndpoint
  { qbeEndpoint :: !RegisteredEndpoint,
    qbeNativeAccountId :: !Text,
    qbeAnchorMessageSeq :: !(Maybe Text)
  }
  deriving stock (Eq, Show)

newtype QQBackfillRunId = QQBackfillRunId Int64
  deriving stock (Eq, Show)

data QQBackfillResult = QQBackfillResult
  { qbrStatus :: !Text,
    qbrFetchedCount :: !Int,
    qbrInsertedCount :: !Int,
    qbrDuplicateCount :: !Int,
    qbrSkippedAfterCutoff :: !Int,
    qbrParseFailureCount :: !Int,
    qbrStopReason :: !Text,
    qbrError :: !(Maybe Text)
  }
  deriving stock (Eq, Show)

-- | Enabled QQ endpoints already known to the canonical registry, newest
-- activity first.  Recovery never discovers/registers arbitrary QQ groups.
listQQBackfillEndpoints ::
  (WithConnection :> es, IOE :> es) =>
  Int ->
  Eff es [QQBackfillEndpoint]
listQQBackfillEndpoints limit = do
  rows <-
    query
      "SELECT e.endpoint_id, e.platform_account_id, e.conversation_id, \
      \       c.legacy_group_id, a.native_account_id, latest.message_seq \
      \  FROM conversation_endpoints e \
      \  JOIN conversations c USING (conversation_id) \
      \  JOIN platform_accounts a USING (platform_account_id) \
      \  LEFT JOIN LATERAL ( \
      \    SELECT pe.raw_payload ->> 'message_seq' AS message_seq, pe.received_at \
      \      FROM platform_events pe \
      \     WHERE pe.endpoint_id = e.endpoint_id AND pe.event_kind = 'message' \
      \       AND pe.raw_payload ->> 'message_seq' IS NOT NULL \
      \     ORDER BY pe.occurred_at DESC, pe.platform_event_id DESC \
      \     LIMIT 1 \
      \  ) latest ON true \
      \ WHERE a.platform = 'qq' AND a.enabled AND e.enabled \
      \   AND c.legacy_group_id IS NOT NULL \
      \ ORDER BY latest.received_at DESC NULLS LAST, e.endpoint_id \
      \ LIMIT ?"
      (Only limit)
  pure (toEndpoint <$> (rows :: [(Int64, Int64, Int64, Int64, Text, Maybe Text)]))
  where
    toEndpoint (endpointId, accountId, conversationId, legacyId, nativeAccountId, anchor) =
      QQBackfillEndpoint
        { qbeEndpoint =
            RegisteredEndpoint
              { endpointId = EndpointId endpointId,
                platformAccountId = PlatformAccountId accountId,
                conversationId = ConversationId conversationId,
                compatibilityConversationId = legacyId
              },
          qbeNativeAccountId = nativeAccountId,
          qbeAnchorMessageSeq = anchor
        }

startQQBackfillRun ::
  (WithConnection :> es, IOE :> es) =>
  Int ->
  QQBackfillEndpoint ->
  UTCTime ->
  Int ->
  Eff es QQBackfillRunId
startQQBackfillRun generation endpoint connectedAt requestedCount = do
  let EndpointId endpointId = endpoint.qbeEndpoint.endpointId
  rows <-
    query
      "INSERT INTO qq_backfill_runs \
      \  (connection_generation, endpoint_id, connected_at, anchor_message_seq, requested_count) \
      \ VALUES (?, ?, ?, ?, ?) RETURNING run_id"
      ( generation,
        endpointId,
        connectedAt,
        endpoint.qbeAnchorMessageSeq,
        requestedCount
      )
  case rows :: [Only Int64] of
    Only runId : _ -> pure (QQBackfillRunId runId)
    [] -> error "QQ backfill run insert returned no id"

finishQQBackfillRun ::
  (WithConnection :> es, IOE :> es) =>
  QQBackfillRunId ->
  QQBackfillResult ->
  Eff es ()
finishQQBackfillRun (QQBackfillRunId runId) result = do
  changed <-
    execute
      "UPDATE qq_backfill_runs \
      \   SET finished_at = now(), status = ?, fetched_count = ?, inserted_count = ?, \
      \       duplicate_count = ?, skipped_after_cutoff = ?, parse_failure_count = ?, \
      \       stop_reason = ?, error = ? \
      \ WHERE run_id = ? AND status = 'running'"
      ( result.qbrStatus,
        result.qbrFetchedCount,
        result.qbrInsertedCount,
        result.qbrDuplicateCount,
        result.qbrSkippedAfterCutoff,
        result.qbrParseFailureCount,
        result.qbrStopReason,
        result.qbrError,
        runId
      )
  if changed == 1
    then pure ()
    else error "QQ backfill run was not running at completion"
