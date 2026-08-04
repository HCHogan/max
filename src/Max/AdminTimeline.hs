-- | Canonical, hydrated conversation timeline for the admin API.
module Max.AdminTimeline
  ( loadAdminTimeline,
  )
where

import Data.Aeson (Result (..), Value, fromJSON, object, (.=))
import Data.Int (Int64)
import Data.Text (Text)
import Data.Time (UTCTime)
import Database.PostgreSQL.Simple.FromRow (FromRow (..), field)
import Database.PostgreSQL.Simple.Types (Only (..))
import Effectful
import Effectful.PostgreSQL (WithConnection, query)
import Max.IR (Body, Phase (Canonical))
import Max.IR.Hydrate (hydrate, hydratedBodyValue)
import Max.Platform.Types (CanonicalMessageId (..))

data TimelineRow = TimelineRow
  { canonicalId :: !Int64,
    conversationSeq :: !Int64,
    compatibilityId :: !Int64,
    authorPrincipalId :: !Int64,
    authorDisplay :: !(Maybe Text),
    sourcePlatform :: !Text,
    eventKind :: !Text,
    occurredAt :: !UTCTime,
    messageOrigin :: !Text,
    transcriptKind :: !Text,
    replyTarget :: !(Maybe Int64),
    promptProjection :: !Text,
    canonicalContent :: !Value
  }

instance FromRow TimelineRow where
  fromRow =
    TimelineRow
      <$> field <*> field <*> field <*> field <*> field <*> field <*> field
      <*> field <*> field <*> field <*> field <*> field <*> field

loadAdminTimeline ::
  (WithConnection :> es, IOE :> es) =>
  Int64 ->
  Maybe Int64 ->
  Int ->
  Eff es (Maybe Value)
loadAdminTimeline legacyConversation after requestedLimit = do
  conversations <-
    query
      "SELECT conversation_id, title FROM conversations WHERE legacy_group_id = ?"
      (Only legacyConversation)
  case conversations :: [(Int64, Maybe Text)] of
    [] -> pure Nothing
    [(conversation, title)] -> do
      endpoints <- endpointValues conversation
      rows <- timelineRows conversation after (max 1 (min 200 requestedLimit))
      items <- traverse timelineValue rows
      pure . Just $
        object
          [ "conversation_id" .= conversation,
            "compatibility_conversation_id" .= legacyConversation,
            "title" .= title,
            "endpoints" .= endpoints,
            "items" .= items,
            "latest_conversation_seq"
              .= case reverse rows of
                row : _ -> Just row.conversationSeq
                [] -> after
          ]
    _ -> error "loadAdminTimeline: duplicate legacy conversation id"

endpointValues ::
  (WithConnection :> es, IOE :> es) =>
  Int64 ->
  Eff es [Value]
endpointValues conversation = do
  rows <-
    query
      "SELECT jsonb_build_object( \
      \ 'endpoint_id', endpoint.endpoint_id, \
      \ 'platform', account.platform, \
      \ 'native_account_id', account.native_account_id, \
      \ 'native_conversation_id', endpoint.native_conversation_id, \
      \ 'mode', endpoint.endpoint_mode, \
      \ 'enabled', endpoint.enabled AND account.enabled, \
      \ 'capabilities', CASE WHEN endpoint.capabilities = '{}'::jsonb \
      \                      THEN account.capabilities ELSE endpoint.capabilities END) \
      \ FROM conversation_endpoints endpoint \
      \ JOIN platform_accounts account USING (platform_account_id) \
      \ WHERE endpoint.conversation_id = ? \
      \ ORDER BY endpoint.endpoint_id"
      (Only conversation)
  pure (fromOnly <$> rows)

timelineRows ::
  (WithConnection :> es, IOE :> es) =>
  Int64 ->
  Maybe Int64 ->
  Int ->
  Eff es [TimelineRow]
timelineRows conversation after limit =
  query
    "SELECT selected.canonical_message_id, selected.conversation_seq, selected.message_id, \
    \       selected.author_principal_id, selected.author_display, selected.source_platform, \
    \       selected.event_kind, selected.occurred_at, selected.message_origin, selected.kind, \
    \       selected.reply_to_canonical_message_id, selected.rendered_text, selected.canonical_content \
    \ FROM ( \
    \   SELECT message.canonical_message_id, message.conversation_seq, message.message_id, \
    \          message.author_principal_id, principal.display_name AS author_display, \
    \          message.source_platform, message.event_kind, message.occurred_at, \
    \          message.message_origin, message.kind, message.reply_to_canonical_message_id, \
    \          message.rendered_text, message.canonical_content \
    \   FROM messages message \
    \   JOIN principals principal ON principal.principal_id = message.author_principal_id \
    \   WHERE message.conversation_id = ? \
    \     AND (?::bigint IS NULL OR message.conversation_seq > ?) \
    \   ORDER BY message.conversation_seq DESC \
    \   LIMIT ? \
    \ ) selected \
    \ ORDER BY selected.conversation_seq"
    (conversation, after, after, limit)

timelineValue ::
  (WithConnection :> es, IOE :> es) =>
  TimelineRow ->
  Eff es Value
timelineValue row = do
  canonical <- case fromJSON row.canonicalContent of
    Success body -> pure (body :: Body 'Canonical)
    Error err -> error ("admin timeline encountered invalid canonical body: " <> err)
  hydrated <- hydrate (CanonicalMessageId row.canonicalId) canonical
  deliveries <- deliveryValues row.canonicalId
  relations <- relationValues row.canonicalId
  pure $
    object
      [ "canonical_message_id" .= row.canonicalId,
        "conversation_seq" .= row.conversationSeq,
        "compatibility_message_id" .= row.compatibilityId,
        "author_principal_id" .= row.authorPrincipalId,
        "author_display" .= row.authorDisplay,
        "source_platform" .= row.sourcePlatform,
        "event_kind" .= row.eventKind,
        "occurred_at" .= row.occurredAt,
        "message_origin" .= row.messageOrigin,
        "transcript_kind" .= row.transcriptKind,
        "reply_to_canonical_message_id" .= row.replyTarget,
        "prompt_projection" .= row.promptProjection,
        "body" .= hydratedBodyValue hydrated,
        "relations" .= relations,
        "deliveries" .= deliveries
      ]

deliveryValues ::
  (WithConnection :> es, IOE :> es) =>
  Int64 ->
  Eff es [Value]
deliveryValues canonical = do
  rows <-
    query
      "SELECT jsonb_build_object( \
      \ 'delivery_id', delivery.delivery_id, \
      \ 'endpoint_id', delivery.endpoint_id, \
      \ 'platform', account.platform, \
      \ 'status', delivery.status, \
      \ 'native_event_id', delivery.native_event_id, \
      \ 'attempt_count', delivery.attempt_count, \
      \ 'last_error', delivery.last_error, \
      \ 'lower_notes', delivery.lower_notes, \
      \ 'updated_at', delivery.updated_at) \
      \ FROM message_deliveries delivery \
      \ JOIN conversation_endpoints endpoint USING (endpoint_id) \
      \ JOIN platform_accounts account USING (platform_account_id) \
      \ WHERE delivery.canonical_message_id = ? \
      \ ORDER BY delivery.endpoint_id"
      (Only canonical)
  pure (fromOnly <$> rows)

relationValues ::
  (WithConnection :> es, IOE :> es) =>
  Int64 ->
  Eff es [Value]
relationValues canonical = do
  rows <-
    query
      "SELECT jsonb_build_object( \
      \ 'kind', relation.relation_kind, \
      \ 'target_canonical_message_id', relation.target_canonical_message_id, \
      \ 'target_native_event_id', relation.target_native_event_id, \
      \ 'reaction_key', relation.reaction_key, \
      \ 'reaction_added', relation.reaction_added, \
      \ 'position', relation.relation_position) \
      \ FROM message_relations relation \
      \ WHERE relation.canonical_message_id = ? \
      \ ORDER BY relation.relation_id"
      (Only canonical)
  pure (fromOnly <$> rows)
