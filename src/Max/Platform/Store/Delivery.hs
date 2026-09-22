{-# LANGUAGE DeriveGeneric #-}

module Max.Platform.Store.Delivery
  ( DeliveryRequest (..),
    DeliveryCompletion (..),
    UnconfirmedDelivery (..),
    DeliveryTarget (..),
    deliveryProcessBoundary,
    deliveryTargets,
    deliveryMentionNatives,
    loadDelivery,
    startDelivery,
    completeDelivery,
    listUnconfirmedDeliveries,
    confirmUnconfirmedDelivery,
    retryUnconfirmedDelivery,
  )
where

import Data.Aeson (ToJSON (toJSON), Value)
import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (listToMaybe)
import Data.Text (Text)
import Data.Time (UTCTime)
import Database.PostgreSQL.Simple.FromRow (FromRow (..), field)
import Database.PostgreSQL.Simple.Types (Only (..), PGArray (..))
import Effectful (Eff, IOE, type (:>))
import Effectful.PostgreSQL (WithConnection, execute, query)
import GHC.Generics (Generic)
import Max.DB.Codec
  ( Jsonb (..),
    enumField,
    exactlyOne,
    jsonbField,
    nullableJsonbField,
  )
import Max.DB.Transaction (withTransaction)
import Max.IR (Body, Phase (Canonical), plainText)
import Max.IR.Lower
  ( Attribution (..),
    LowerNote,
    OutboundCaps,
    ReplyContext (..),
    outboundCapsFromValue,
    platformDisplayLabel,
  )
import Max.Platform.Types
  ( CanonicalMessageId (CanonicalMessageId),
    DeliveryId (DeliveryId),
    EndpointId (EndpointId),
    EventKind,
    NativeAccountId (NativeAccountId),
    NativeConversationId (NativeConversationId),
    NativeEventId (..),
    NativeUserId (NativeUserId),
    Platform,
    PlatformAccountId (PlatformAccountId),
    PrincipalIdentityId (..),
    ReactionAction (..),
    parseEventKind,
    parsePlatform,
    renderPlatform,
  )

data DeliveryRequest = DeliveryRequest
  { deliveryId :: !DeliveryId,
    canonicalMessageId :: !CanonicalMessageId,
    endpointId :: !EndpointId,
    platformAccountId :: !PlatformAccountId,
    platform :: !Platform,
    nativeAccountId :: !NativeAccountId,
    nativeConversationId :: !NativeConversationId,
    body :: !(Body 'Canonical),
    eventKind :: !EventKind,
    actionTarget :: !(Maybe NativeEventId),
    reactionKey :: !(Maybe Text),
    reactionAction :: !ReactionAction,
    previousReactionNative :: !(Maybe NativeEventId),
    compatibilityConversationId :: !Int64,
    replyContext :: !(Maybe ReplyContext),
    attribution :: !(Maybe Attribution),
    idempotencyKey :: !Text,
    attemptCount :: !Int,
    capabilities :: !OutboundCaps
  }
  deriving stock (Eq, Show, Generic)

data DeliveryCompletion
  = DeliveryConfirmedAs !(Maybe NativeEventId)
  | DeliveryAccepted !(Maybe NativeEventId)
  | DeliveryRetry !Text !UTCTime
  | DeliveryUnknown !Text !UTCTime
  | DeliveryPermanentlyFailed !Text
  | DeliverySuppressedAs !Text
  deriving stock (Eq, Show, Generic)

-- | A non-idempotent send accepted by the edge but not yet proven by an echo
-- or provider status.  These rows are intentionally absent from the delivery
-- send queue: only reconciliation may move them again.
data UnconfirmedDelivery = UnconfirmedDelivery
  { deliveryId :: !DeliveryId,
    nativeEventId :: !NativeEventId,
    updatedAt :: !UTCTime
  }
  deriving stock (Eq, Show, Generic)

data DeliveryRequestRow = DeliveryRequestRow
  { dcDeliveryId :: !Int64,
    dcCanonicalMessageId :: !Int64,
    dcEndpointId :: !Int64,
    dcPlatformAccountId :: !Int64,
    dcPlatform :: !Text,
    dcNativeAccountId :: !Text,
    dcNativeConversationId :: !Text,
    dcContent :: !(Body 'Canonical),
    dcEventKind :: !EventKind,
    dcActionTarget :: !(Maybe Text),
    dcReactionKey :: !(Maybe Text),
    dcReactionAdded :: !Bool,
    dcPreviousReactionNative :: !(Maybe Text),
    dcCompatibilityConversationId :: !Int64,
    dcReplyNativeEventId :: !(Maybe Text),
    dcReplyAuthor :: !(Maybe Text),
    dcReplyContent :: !(Maybe (Body 'Canonical)),
    dcOriginPlatform :: !Text,
    dcSenderDisplayName :: !(Maybe Text),
    dcMessageOrigin :: !Text,
    dcIdempotencyKey :: !Text,
    dcAttemptCount :: !Int,
    dcCapabilities :: !Value
  }

instance FromRow DeliveryRequestRow where
  fromRow = do
    dcDeliveryId <- field
    dcCanonicalMessageId <- field
    dcEndpointId <- field
    dcPlatformAccountId <- field
    dcPlatform <- field
    dcNativeAccountId <- field
    dcNativeConversationId <- field
    dcContent <- jsonbField
    dcEventKind <- enumField parseEventKind
    dcActionTarget <- field
    dcReactionKey <- field
    dcReactionAdded <- field
    dcPreviousReactionNative <- field
    dcCompatibilityConversationId <- field
    dcReplyNativeEventId <- field
    dcReplyAuthor <- field
    dcReplyContent <- nullableJsonbField
    dcOriginPlatform <- field
    dcSenderDisplayName <- field
    dcMessageOrigin <- field
    dcIdempotencyKey <- field
    dcAttemptCount <- field
    dcCapabilities <- field
    pure
      DeliveryRequestRow
        { dcDeliveryId,
          dcCanonicalMessageId,
          dcEndpointId,
          dcPlatformAccountId,
          dcPlatform,
          dcNativeAccountId,
          dcNativeConversationId,
          dcContent,
          dcEventKind,
          dcActionTarget,
          dcReactionKey,
          dcReactionAdded,
          dcPreviousReactionNative,
          dcCompatibilityConversationId,
          dcReplyNativeEventId,
          dcReplyAuthor,
          dcReplyContent,
          dcOriginPlatform,
          dcSenderDisplayName,
          dcMessageOrigin,
          dcIdempotencyKey,
          dcAttemptCount,
          dcCapabilities
        }

-- | The queue stores only routing identity; load content and native references
-- immediately before an attempt so earlier sends can supply reply targets.
data DeliveryTarget = DeliveryTarget
  { deliveryId :: !DeliveryId,
    endpointId :: !EndpointId,
    platform :: !Platform
  }
  deriving stock (Eq, Show)

-- | Reserve a sequence boundary before ingress starts. Receipt reconciliation
-- may schedule only this process's publications, never an old accepted send.
deliveryProcessBoundary :: (WithConnection :> es, IOE :> es) => Eff es DeliveryId
deliveryProcessBoundary = withTransaction $ do
  rows <- query "SELECT nextval('message_deliveries_delivery_id_seq')" ()
  let boundary = exactlyOne "delivery process boundary" rows
  _ <- execute "UPDATE message_delivery_parts SET status='outcome_unknown',last_error=COALESCE(last_error,'process ended before receipt'),updated_at=now() WHERE delivery_id<? AND status='sending'" (Only boundary)
  _ <- execute "UPDATE message_deliveries SET status=CASE WHEN status='sending' THEN 'outcome_unknown' ELSE 'suppressed' END,last_error=COALESCE(last_error,'process ended; not replayed'),lease_owner=NULL,lease_expires_at=NULL,updated_at=now() WHERE delivery_id<? AND status IN ('pending','reserved','sending','failed')" (Only boundary)
  pure (DeliveryId boundary)

deliveryTargets :: (WithConnection :> es, IOE :> es) => CanonicalMessageId -> Eff es [DeliveryTarget]
deliveryTargets (CanonicalMessageId canonical) = do
  rows <- query "SELECT d.delivery_id,d.endpoint_id,a.platform FROM message_deliveries d JOIN conversation_endpoints e USING(endpoint_id) JOIN platform_accounts a USING(platform_account_id) WHERE d.canonical_message_id=? AND d.status='pending' ORDER BY d.delivery_id" (Only canonical)
  pure [DeliveryTarget (DeliveryId delivery) (EndpointId endpoint) (parsePlatform platform) | (delivery, endpoint, platform) <- rows]

deliveryMentionNatives ::
  (WithConnection :> es, IOE :> es) =>
  EndpointId ->
  [PrincipalIdentityId] ->
  Eff es (Map PrincipalIdentityId NativeUserId)
deliveryMentionNatives _ [] = pure Map.empty
deliveryMentionNatives (EndpointId endpoint) identities = do
  rows <-
    query
      "SELECT DISTINCT ON (source.principal_identity_id) \
      \       source.principal_identity_id, destination.native_user_id \
      \ FROM principal_identities source \
      \ JOIN conversation_endpoints endpoint ON endpoint.endpoint_id = ? \
      \ JOIN principal_identities destination \
      \   ON destination.principal_id = source.principal_id \
      \  AND destination.platform_account_id = endpoint.platform_account_id \
      \ WHERE source.principal_identity_id = ANY(?) \
      \ ORDER BY source.principal_identity_id, \
      \          (destination.principal_identity_id = source.principal_identity_id) DESC, \
      \          destination.updated_at DESC, \
      \          destination.principal_identity_id DESC"
      (endpoint, PGArray (map unPrincipalIdentityId identities))
  pure . Map.fromList $
    [ (PrincipalIdentityId identity, NativeUserId native)
    | (identity, native) <- (rows :: [(Int64, Text)])
    ]

loadDelivery :: (WithConnection :> es, IOE :> es) => DeliveryId -> Eff es (Maybe DeliveryRequest)
loadDelivery (DeliveryId delivery) = do
  rows <-
    query
      "SELECT c.delivery_id, c.canonical_message_id, c.endpoint_id, a.platform_account_id, a.platform, \
      \        a.native_account_id, e.native_conversation_id, m.canonical_content, \
      \        m.event_kind, action_copy.native_event_id, action_relation.reaction_key, \
      \        COALESCE(action_relation.reaction_added, true), previous_reaction.native_event_id, \
      \        m.group_id, \
      \        reply_copy.native_event_id, \
      \        COALESCE(reply_message.sender_card, reply_message.sender_nickname), \
      \        reply_message.canonical_content, \
      \        origin_account.platform, COALESCE(m.sender_card, m.sender_nickname), m.message_origin, \
      \        c.idempotency_key, c.attempt_count, \
      \        CASE WHEN e.capabilities = '{}'::jsonb THEN a.capabilities ELSE e.capabilities END \
      \ FROM message_deliveries c \
      \ JOIN conversation_endpoints e ON e.endpoint_id = c.endpoint_id \
      \ JOIN platform_accounts a ON a.platform_account_id = e.platform_account_id \
      \ JOIN messages m ON m.canonical_message_id = c.canonical_message_id \
      \ JOIN conversation_endpoints origin_endpoint ON origin_endpoint.endpoint_id = m.origin_endpoint_id \
      \ JOIN platform_accounts origin_account ON origin_account.platform_account_id = origin_endpoint.platform_account_id \
      \ LEFT JOIN LATERAL ( \
      \   SELECT relation.target_canonical_message_id, relation.target_native_event_id, \
      \          relation.reaction_key, relation.reaction_added \
      \   FROM message_relations relation \
      \   WHERE relation.canonical_message_id = c.canonical_message_id \
      \     AND relation.relation_kind = CASE m.event_kind \
      \       WHEN 'edit' THEN 'replace' WHEN 'reaction' THEN 'reaction' \
      \       WHEN 'redaction' THEN 'redacts' ELSE '__none__' END \
      \   ORDER BY relation.created_at DESC, relation.relation_id DESC LIMIT 1 \
      \ ) action_relation ON true \
      \ LEFT JOIN LATERAL ( \
      \   SELECT copies.native_event_id FROM ( \
      \     SELECT pe.native_event_id, 0 AS source_rank, pe.occurred_at AS copied_at, \
      \            pe.platform_event_id AS copy_id \
      \     FROM platform_events pe \
      \     WHERE pe.endpoint_id = c.endpoint_id \
      \       AND (pe.canonical_message_id = action_relation.target_canonical_message_id \
      \            OR (action_relation.target_canonical_message_id IS NULL \
      \                AND pe.native_event_id = action_relation.target_native_event_id)) \
      \     UNION ALL \
      \     SELECT target_delivery.native_event_id, 1 AS source_rank, target_delivery.updated_at AS copied_at, \
      \            target_delivery.delivery_id AS copy_id \
      \     FROM message_delivery_copies target_delivery \
      \     WHERE target_delivery.endpoint_id = c.endpoint_id \
      \       AND target_delivery.native_event_id IS NOT NULL \
      \       AND (target_delivery.canonical_message_id = action_relation.target_canonical_message_id \
      \            OR (action_relation.target_canonical_message_id IS NULL \
      \                AND target_delivery.native_event_id = action_relation.target_native_event_id)) \
      \   ) copies \
      \   ORDER BY CASE WHEN copies.native_event_id = action_relation.target_native_event_id THEN 0 ELSE 1 END, copies.source_rank, copies.copied_at DESC, copies.copy_id DESC LIMIT 1 \
      \ ) action_copy ON true \
      \ LEFT JOIN LATERAL ( \
      \   SELECT copies.native_event_id FROM ( \
      \     SELECT pe.native_event_id, 0 AS source_rank, pe.occurred_at AS copied_at, \
      \            pe.platform_event_id AS copy_id, prior_message.conversation_seq \
      \     FROM message_relations prior_relation \
      \     JOIN messages prior_message \
      \       ON prior_message.canonical_message_id = prior_relation.canonical_message_id \
      \     JOIN platform_events pe \
      \       ON pe.endpoint_id = c.endpoint_id \
      \      AND pe.canonical_message_id = prior_relation.canonical_message_id \
      \     WHERE m.event_kind = 'reaction' AND NOT action_relation.reaction_added \
      \       AND prior_relation.relation_kind = 'reaction' AND prior_relation.reaction_added \
      \       AND prior_relation.target_canonical_message_id \
      \           IS NOT DISTINCT FROM action_relation.target_canonical_message_id \
      \       AND prior_relation.reaction_key IS NOT DISTINCT FROM action_relation.reaction_key \
      \       AND prior_message.conversation_seq < m.conversation_seq \
      \     UNION ALL \
      \     SELECT prior_delivery.native_event_id, 1 AS source_rank, prior_delivery.updated_at AS copied_at, \
      \            prior_delivery.delivery_id AS copy_id, prior_message.conversation_seq \
      \     FROM message_relations prior_relation \
      \     JOIN messages prior_message \
      \       ON prior_message.canonical_message_id = prior_relation.canonical_message_id \
      \     JOIN message_delivery_copies prior_delivery \
      \       ON prior_delivery.endpoint_id = c.endpoint_id \
      \      AND prior_delivery.canonical_message_id = prior_relation.canonical_message_id \
      \      AND prior_delivery.native_event_id IS NOT NULL \
      \     WHERE m.event_kind = 'reaction' AND NOT action_relation.reaction_added \
      \       AND prior_relation.relation_kind = 'reaction' AND prior_relation.reaction_added \
      \       AND prior_relation.target_canonical_message_id \
      \           IS NOT DISTINCT FROM action_relation.target_canonical_message_id \
      \       AND prior_relation.reaction_key IS NOT DISTINCT FROM action_relation.reaction_key \
      \       AND prior_message.conversation_seq < m.conversation_seq \
      \   ) copies \
      \   ORDER BY copies.conversation_seq DESC, copies.source_rank, copies.copied_at DESC, copies.copy_id DESC \
      \   LIMIT 1 \
      \ ) previous_reaction ON true \
      \ LEFT JOIN LATERAL ( \
      \   SELECT relation.target_canonical_message_id, relation.target_native_event_id \
      \   FROM message_relations relation \
      \   WHERE relation.canonical_message_id = c.canonical_message_id \
      \     AND relation.relation_kind = 'reply' \
      \   ORDER BY relation.created_at DESC, relation.relation_id DESC LIMIT 1 \
      \ ) reply_relation ON true \
      \ LEFT JOIN messages reply_message \
      \   ON reply_message.canonical_message_id = reply_relation.target_canonical_message_id \
      \ LEFT JOIN LATERAL ( \
      \   SELECT copies.native_event_id FROM ( \
      \     SELECT pe.native_event_id, 0 AS source_rank, pe.occurred_at AS copied_at, pe.platform_event_id AS copy_id \
      \     FROM platform_events pe \
      \     WHERE pe.endpoint_id = c.endpoint_id \
      \       AND (pe.canonical_message_id = reply_relation.target_canonical_message_id \
      \            OR pe.native_event_id = reply_relation.target_native_event_id) \
      \     UNION ALL \
      \     SELECT target_delivery.native_event_id, 1 AS source_rank, target_delivery.updated_at AS copied_at, \
      \            target_delivery.delivery_id AS copy_id \
      \     FROM message_delivery_copies target_delivery \
      \     WHERE target_delivery.endpoint_id = c.endpoint_id \
      \       AND target_delivery.native_event_id IS NOT NULL \
      \       AND (target_delivery.canonical_message_id = reply_relation.target_canonical_message_id \
      \            OR target_delivery.native_event_id = reply_relation.target_native_event_id) \
      \   ) copies \
      \   ORDER BY CASE WHEN copies.native_event_id = reply_relation.target_native_event_id THEN 0 ELSE 1 END, copies.source_rank, copies.copied_at DESC, copies.copy_id DESC LIMIT 1 \
      \ ) reply_copy ON true \
      \ WHERE c.delivery_id = ? AND e.enabled AND a.enabled"
      (Only delivery)
  pure (toDeliveryRequest <$> listToMaybe (rows :: [DeliveryRequestRow]))

-- | Record the transport phase for echoes and inspection. Ownership and retry
-- scheduling belong to the process queue, not this diagnostic row.
startDelivery :: (WithConnection :> es, IOE :> es) => DeliveryId -> Int -> Eff es Bool
startDelivery (DeliveryId delivery) attempt = do
  changed <-
    execute
      "UPDATE message_deliveries SET status='sending',attempt_count=?,last_attempt_at=now(),updated_at=now() WHERE delivery_id=? AND status IN ('pending','failed')"
      (attempt, delivery)
  pure (changed == 1)

completeDelivery ::
  (WithConnection :> es, IOE :> es) =>
  DeliveryId ->
  [LowerNote] ->
  DeliveryCompletion ->
  Eff es Bool
completeDelivery (DeliveryId delivery) lowerNotes completion = do
  withTransaction $ do
    lockDeliveryParent delivery
    safeCompletion <- discardOwnedNativeEvent completion
    changed <- case safeCompletion of
      DeliveryConfirmedAs native ->
        finish ("confirmed" :: Text) native Nothing Nothing True
      DeliveryAccepted native -> do
        rows <- query "SELECT EXISTS (SELECT 1 FROM message_delivery_parts WHERE delivery_id=?) AND NOT EXISTS (SELECT 1 FROM message_delivery_parts WHERE delivery_id=? AND status<>'confirmed'), EXISTS (SELECT 1 FROM message_delivery_parts WHERE delivery_id=? AND status='retry')" (delivery, delivery, delivery)
        let (confirmed, retry) = case rows of [flags] -> flags; _ -> (False, False)
            status | retry = "failed" | confirmed = "confirmed" | otherwise = "accepted_unconfirmed"
        finish status native (if retry then Just "provider rejected a part during delivery" else Nothing) Nothing confirmed
      DeliveryRetry err next ->
        finish "failed" Nothing (Just err) (Just next) False
      DeliveryUnknown err next ->
        finish "outcome_unknown" Nothing (Just err) (Just next) False
      DeliveryPermanentlyFailed err ->
        finish "permanent_failure" Nothing (Just err) Nothing False
      DeliverySuppressedAs reason ->
        finish "suppressed" Nothing (Just reason) Nothing False
    pure (changed == 1)
  where
    discardOwnedNativeEvent value = case value of
      DeliveryConfirmedAs (Just native) ->
        nativeEventAlreadyOwned native >>= \owned ->
          pure (DeliveryConfirmedAs (if owned then Nothing else Just native))
      DeliveryAccepted (Just native) ->
        nativeEventAlreadyOwned native >>= \owned ->
          pure (DeliveryAccepted (if owned then Nothing else Just native))
      _ -> pure value

    nativeEventAlreadyOwned (NativeEventId native) = do
      rows <-
        query
          "SELECT EXISTS (\
          \ SELECT 1 FROM message_deliveries target\
          \ JOIN message_delivery_copies owner ON owner.endpoint_id = target.endpoint_id\
          \ WHERE target.delivery_id = ? AND owner.delivery_id <> target.delivery_id\
          \   AND owner.native_event_id = ?)"
          (delivery, native)
      pure $ case rows of
        [Only owned] -> owned
        _ -> False

    finish status native lastError next confirmed =
      execute
        "UPDATE message_deliveries \
        \ SET status = ?, native_event_id = COALESCE(?, native_event_id), \
        \     lower_notes = ?, \
        \     last_error = ?, next_attempt_at = COALESCE(?, next_attempt_at), \
        \     confirmed_at = CASE WHEN ? THEN now() ELSE confirmed_at END, \
        \     lease_owner = NULL, lease_expires_at = NULL, updated_at = now() \
        \ WHERE delivery_id = ? AND status IN ('pending','failed','sending')"
        ( status,
          unNativeEventId <$> native,
          Jsonb (toJSON lowerNotes),
          lastError,
          next,
          confirmed,
          delivery
        )

listUnconfirmedDeliveries ::
  (WithConnection :> es, IOE :> es) => Platform -> Int -> Eff es [UnconfirmedDelivery]
listUnconfirmedDeliveries platform limit = do
  rows <-
    query
      "SELECT d.delivery_id,d.native_event_id,d.updated_at FROM message_delivery_copies d JOIN conversation_endpoints e USING(endpoint_id) JOIN platform_accounts a USING(platform_account_id) WHERE a.platform=? AND d.status='accepted_unconfirmed' AND d.part_status='accepted_unconfirmed' ORDER BY d.updated_at,d.delivery_id LIMIT ?"
      (renderPlatform platform, limit)
  pure [UnconfirmedDelivery (DeliveryId delivery) (NativeEventId native) updated | (delivery, native, updated) <- rows]

-- | Provider status settles one part. The parent is confirmed only after all
-- parts are proven; historical deliveries retain their single-receipt behavior.
confirmUnconfirmedDelivery ::
  (WithConnection :> es, IOE :> es) => DeliveryId -> NativeEventId -> Eff es Bool
confirmUnconfirmedDelivery (DeliveryId delivery) (NativeEventId native) = withTransaction $ do
  lockDeliveryParent delivery
  parts <- execute "UPDATE message_delivery_parts SET status='confirmed',last_error=NULL,updated_at=now() WHERE delivery_id=? AND native_event_id=? AND status='accepted_unconfirmed'" (delivery, native)
  changed <-
    execute
      "UPDATE message_deliveries d SET status='confirmed',confirmed_at=now(),last_error=NULL,updated_at=now() WHERE delivery_id=? AND status='accepted_unconfirmed' AND ((native_event_id=? AND NOT EXISTS (SELECT 1 FROM message_delivery_parts p WHERE p.delivery_id=d.delivery_id)) OR (EXISTS (SELECT 1 FROM message_delivery_parts p WHERE p.delivery_id=d.delivery_id) AND NOT EXISTS (SELECT 1 FROM message_delivery_parts p WHERE p.delivery_id=d.delivery_id AND p.status<>'confirmed')))"
      (delivery, native)
  pure (parts > 0 || changed > 0)

-- | Explicit provider failure permits retrying this part alone. Successful
-- siblings keep their receipts and will be skipped by the transport runner.
retryUnconfirmedDelivery ::
  (WithConnection :> es, IOE :> es) => DeliveryId -> NativeEventId -> Text -> Eff es Bool
retryUnconfirmedDelivery (DeliveryId delivery) (NativeEventId native) reason = withTransaction $ do
  lockDeliveryParent delivery
  parts <- execute "UPDATE message_delivery_parts SET status='retry',native_event_id=NULL,last_error=?,updated_at=now() WHERE delivery_id=? AND native_event_id=? AND status='accepted_unconfirmed'" (reason, delivery, native)
  changed <-
    execute
      "UPDATE message_deliveries d SET status=CASE WHEN status='sending' THEN 'sending' ELSE 'failed' END,next_attempt_at=now(),last_error=?,updated_at=now(),native_event_id=CASE WHEN native_event_id=? THEN NULL ELSE native_event_id END WHERE delivery_id=? AND status IN ('accepted_unconfirmed','sending') AND (? OR (native_event_id=? AND NOT EXISTS (SELECT 1 FROM message_delivery_parts p WHERE p.delivery_id=d.delivery_id)))"
      (reason, native, delivery, parts > 0, native)
  pure (parts > 0 || changed > 0)

lockDeliveryParent :: (WithConnection :> es, IOE :> es) => Int64 -> Eff es ()
lockDeliveryParent delivery = do
  rows <- query "SELECT delivery_id FROM message_deliveries WHERE delivery_id=? FOR UPDATE" (Only delivery)
  let _ = rows :: [Only Int64]
  pure ()

toDeliveryRequest :: DeliveryRequestRow -> DeliveryRequest
toDeliveryRequest row =
  let destination = parsePlatform row.dcPlatform
      origin = parsePlatform row.dcOriginPlatform
      replyBody = row.dcReplyContent
      replyContext = case (row.dcReplyNativeEventId, row.dcReplyAuthor, replyBody) of
        (Nothing, Nothing, Nothing) -> Nothing
        (native, author, targetBody) ->
          Just
            ReplyContext
              { nativeId = NativeEventId <$> native,
                author,
                excerpt = plainText <$> targetBody
              }
      attribution
        | row.dcMessageOrigin == "inbound" && origin /= destination =
            Just
              Attribution
                { platformLabel = platformDisplayLabel origin,
                  sender = row.dcSenderDisplayName
                }
        | otherwise = Nothing
   in DeliveryRequest
        { deliveryId = DeliveryId row.dcDeliveryId,
          canonicalMessageId = CanonicalMessageId row.dcCanonicalMessageId,
          endpointId = EndpointId row.dcEndpointId,
          platformAccountId = PlatformAccountId row.dcPlatformAccountId,
          platform = destination,
          nativeAccountId = NativeAccountId row.dcNativeAccountId,
          nativeConversationId = NativeConversationId row.dcNativeConversationId,
          body = row.dcContent,
          eventKind = row.dcEventKind,
          actionTarget = NativeEventId <$> row.dcActionTarget,
          reactionKey = row.dcReactionKey,
          reactionAction = if row.dcReactionAdded then ReactionAdd else ReactionRemove,
          previousReactionNative = NativeEventId <$> row.dcPreviousReactionNative,
          compatibilityConversationId = row.dcCompatibilityConversationId,
          replyContext,
          attribution,
          idempotencyKey = row.dcIdempotencyKey,
          attemptCount = row.dcAttemptCount,
          capabilities = outboundCapsFromValue row.dcCapabilities
        }
