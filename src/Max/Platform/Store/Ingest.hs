{-# LANGUAGE DeriveGeneric #-}

module Max.Platform.Store.Ingest
  ( IngestOptions (..),
    defaultIngestOptions,
    IngestResult (..),
    NewIngest (..),
    CursorRecord (..),
    ingestEnvelope,
    readIngestCursor,
    advanceIngestCursorCAS,
    loadDispatchMessage,
  )
where

import Control.Applicative ((<|>))
import Control.Monad (forM, forM_, join, when)
import Data.Aeson (ToJSON (toJSON), Value)
import Data.Int (Int64)
import Data.List (find)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, listToMaybe, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Database.PostgreSQL.Simple ((:.) (..))
import Database.PostgreSQL.Simple.FromRow (FromRow (..), field)
import Database.PostgreSQL.Simple.Types (Only (..), PGArray (..))
import Effectful (Eff, IOE, type (:>))
import Effectful.PostgreSQL (WithConnection, execute, query)
import GHC.Generics (Generic)
import Max.DB.Codec (Jsonb (Jsonb), jsonbField)
import Max.DB.Monitor (evaluateLedgerMatches)
import Max.DB.PlatformIds (compatibilityId)
import Max.DB.Transaction (withTransaction)
import Max.Dispatch (DispatchMessage (..))
import Max.IR (Body, Phase (Canonical), mentionIdentities)
import Max.IR.Lower
  ( metaCapabilityEnabled,
    outboundCapsFromValue,
  )
import Max.IR.Prompt (promptCanonicalText, systemEventText)
import Max.MessageKind (MessageKind (..), renderMessageKind)
import Max.Platform.Envelope
  ( InboundEnvelope (..),
    IngestClass (..),
  )
import Max.Platform.Sanitize
  ( sanitizeInboundEnvelope,
    sanitizePostgresText,
    sanitizePostgresValue,
    sanitizeRawPayload,
  )
import Max.Platform.Store.Delivery
  ( DeliveryTarget (..),
    deliveryTargets,
  )
import Max.Platform.Store.Endpoint
  ( EndpointRow (..),
    fetchEndpoint,
  )
import Max.Platform.Store.Identity
  ( batchIdentities,
    bodyMentionDisplays,
    ensureIdentityBatch,
    identityPrincipals,
    mentionPrincipalsFor,
    resolveBodyMentions,
  )
import Max.Platform.Store.Relation
  ( insertRelation,
    resolveNativeTarget,
    resolveReply,
  )
import Max.Platform.Types
  ( CanonicalMessageId (CanonicalMessageId),
    EndpointId (unEndpointId),
    EventKind (..),
    MessageRelation (ReactsTo, Redacts, Replaces),
    NativeEventId (NativeEventId),
    NativeUserId (NativeUserId, unNativeUserId),
    PlatformAccountId (PlatformAccountId),
    PlatformCursor (..),
    PrincipalId (PrincipalId),
    ReactionAction (ReactionAdd),
    parsePlatform,
    renderEventKind,
  )
import OneBot.Types (GroupId (..), UserId (..))

data IngestOptions = IngestOptions
  { maxRawPayloadBytes :: !Int,
    createDispatch :: !Bool,
    createMirrorDeliveries :: !Bool,
    transcriptKind :: !Text,
    -- | Raw OneBot segment provenance.  Only the QQ adapter may populate it;
    -- every other platform leaves @messages.segments@ as the frozen empty
    -- array and uses canonical content exclusively.
    qqProvenanceSegments :: !(Maybe Value),
    -- | Treat own-account events only as delivery echoes, including manual sends.
    -- Matches confirm delivery; unmatched events are discarded as 'EchoUnmatched'.
    -- This avoids duplicate ingestion when an echo arrives before the send receipt.
    selfEventsAreEchoes :: !Bool
  }
  deriving stock (Eq, Show, Generic)

defaultIngestOptions :: IngestOptions
defaultIngestOptions =
  IngestOptions
    { maxRawPayloadBytes = 65536,
      createDispatch = True,
      createMirrorDeliveries = True,
      transcriptKind = "chat",
      qqProvenanceSegments = Nothing,
      selfEventsAreEchoes = False
    }

data IngestResult
  = Ingested !NewIngest
  | AlreadyIngested !CanonicalMessageId
  | DeliveryEcho !CanonicalMessageId
  | -- | A 'selfEventsAreEchoes' event that matched no delivery.  Nothing was
    -- written, so the caller may drop it.
    EchoUnmatched
  deriving stock (Eq, Show, Generic)

data NewIngest = NewIngest
  { canonicalMessageId :: !CanonicalMessageId,
    -- | The exact canonical IR committed by this transaction.  Returning it
    -- lets adapter-edge observability log a bounded digest without decoding
    -- the row again or retaining the inbound representation.
    canonicalBody :: !(Body 'Canonical),
    dispatchEligible :: !Bool,
    mirrorDeliveries :: ![DeliveryTarget]
  }
  deriving stock (Eq, Show, Generic)

data CursorRecord = CursorRecord
  { cursor :: !PlatformCursor,
    fingerprint :: !(Maybe Text),
    revision :: !Int64
  }
  deriving stock (Eq, Show, Generic)

data DispatchRow = DispatchRow
  { drCanonical :: !Int64,
    drGroup :: !Int64,
    drUser :: !Int64,
    drSelf :: !Int64,
    drAuthor :: !Int64,
    drSelfPrincipal :: !Int64,
    drBody :: !(Body 'Canonical),
    drReply :: !(Maybe Int64),
    drPlatform :: !Text,
    drName :: !(Maybe Text)
  }

instance FromRow DispatchRow where
  fromRow = do
    drCanonical <- field
    drGroup <- field
    drUser <- field
    drSelf <- field
    drAuthor <- field
    drSelfPrincipal <- field
    drBody <- jsonbField
    drReply <- field
    drPlatform <- field
    drName <- field
    pure
      DispatchRow
        { drCanonical,
          drGroup,
          drUser,
          drSelf,
          drAuthor,
          drSelfPrincipal,
          drBody,
          drReply,
          drPlatform,
          drName
        }

-- | Persist one normalized event exactly once.  The unique native event key is
-- reserved before any canonical row is inserted, and all derived work is
-- published in the same transaction.
ingestEnvelope ::
  (WithConnection :> es, IOE :> es) =>
  IngestOptions ->
  InboundEnvelope ->
  Eff es IngestResult
ingestEnvelope unsafeOptions unsafeEnvelope = withTransaction $ do
  endpoint <- fetchEndpoint envelope.endpointId
  -- Registration/publication lock the conversation before notifying the
  -- timeline. Taking this only during monitor admission reverses that order.
  (_ :: [Only Int64]) <- query "SELECT conversation_id FROM conversations WHERE conversation_id=? FOR UPDATE" (Only endpoint.erConversationId)
  -- Sender and mention identities lock in one ascending batch so two
  -- concurrent ingests can never take identity row locks in opposite
  -- orders.
  identities <-
    ensureIdentityBatch
      endpoint
      ( Map.insertWith
          (<|>)
          -- The bot itself, so "was I addressed?" always has a principal to
          -- compare a mention against on this endpoint (ADR 004).  It is a
          -- member of the conversation like anyone else; only the outbound
          -- path used to say so.
          (NativeUserId endpoint.erNativeAccountId)
          (Just "max")
          ( Map.insertWith
              (<|>)
              envelope.senderNativeId
              envelope.senderDisplayName
              (bodyMentionDisplays envelope.content)
          )
      )
  identityId <- case Map.lookup envelope.senderNativeId identities of
    Just (identity, _) -> pure identity
    Nothing -> error "ingestEnvelope: sender identity missing from batch"
  resolvedCanonicalBody <- resolveBodyMentions (batchIdentities identities) envelope.content
  let contentValue = toJSON resolvedCanonicalBody
      NativeEventId nativeEvent = envelope.nativeEventId
      (safeRaw, rawTruncated) = sanitizeRawPayload options.maxRawPayloadBytes envelope.rawPayload
      ingestLockKey = T.pack (show envelope.endpointId.unEndpointId) <> ":" <> nativeEvent
  -- The platform-event row is initially a reservation and receives its
  -- canonical_message_id later in this transaction. Serialize only identical
  -- native events so a duplicate delivery cannot observe or try to repair
  -- that deliberately intermediate state. The conversation lock also orders
  -- transcript writes and monitor admission against endpoint changes.
  lockRows <-
    query
      "SELECT pg_advisory_xact_lock(hashtextextended(?::text, 0)) IS NULL"
      (Only ingestLockKey)
  case lockRows :: [Only Bool] of
    [_] -> pure ()
    _ -> error "ingestEnvelope: advisory lock did not return one row"
  reconciled <- reconcileDeliveryEcho endpoint identityId contentValue safeRaw rawTruncated
  case reconciled of
    Just cid -> pure (DeliveryEcho (CanonicalMessageId cid))
    Nothing
      | options.selfEventsAreEchoes
          && envelope.senderNativeId.unNativeUserId == endpoint.erNativeAccountId ->
          pure EchoUnmatched
    Nothing -> do
      reserved <-
        query
          "INSERT INTO platform_events \
          \ (endpoint_id, native_event_id, sender_identity_id, event_kind, occurred_at, \
          \  received_at, source_cursor, raw_payload, raw_payload_truncated, ingest_class) \
          \ VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?) \
          \ ON CONFLICT (endpoint_id, native_event_id) DO NOTHING \
          \ RETURNING platform_event_id"
          ( envelope.endpointId.unEndpointId,
            nativeEvent,
            identityId,
            renderEventKind envelope.eventKind,
            envelope.occurredAt,
            envelope.receivedAt,
            Jsonb . unPlatformCursor <$> envelope.sourceCursor,
            Jsonb <$> safeRaw,
            rawTruncated,
            renderIngestClass envelope.ingestClass
          )
      case reserved :: [Only Int64] of
        [] -> do
          existing <-
            query
              "SELECT canonical_message_id FROM platform_events \
              \ WHERE endpoint_id = ? AND native_event_id = ? FOR UPDATE"
              (envelope.endpointId.unEndpointId, nativeEvent)
          case existing :: [Only (Maybe Int64)] of
            [Only (Just cid)] -> pure (AlreadyIngested (CanonicalMessageId cid))
            -- A pre-hardening writer may have committed an incomplete
            -- reservation. The per-native-event transaction lock makes this
            -- caller its sole repair owner.
            [Only Nothing] -> insertCanonical endpoint identityId identities resolvedCanonicalBody contentValue
            _ -> error "ingestEnvelope: event reservation disappeared"
        [_] -> insertCanonical endpoint identityId identities resolvedCanonicalBody contentValue
        _ -> error "ingestEnvelope: event reservation returned multiple rows"
  where
    options = sanitizeIngestOptions unsafeOptions
    envelope = sanitizeInboundEnvelope unsafeEnvelope

    reconcileDeliveryEcho endpoint identityId contentValue safeRaw rawTruncated = do
      let NativeEventId nativeEvent = envelope.nativeEventId
          NativeUserId sender = envelope.senderNativeId
      exact <-
        query
          "SELECT DISTINCT canonical_message_id FROM message_delivery_copies \
          \ WHERE endpoint_id = ? AND native_event_id = ? \
          \   AND idempotency_key NOT LIKE 'source:%'"
          (envelope.endpointId.unEndpointId, nativeEvent)
      candidate <- case exact :: [Only Int64] of
        [Only cid] -> pure (Just cid)
        [] -> do
          meta <- reconcileMetaEcho
          case meta of
            Just cid -> pure (Just cid)
            Nothing
              | envelope.eventKind == EventMessage && sender == endpoint.erNativeAccountId -> do
                  -- A transport can time out after accepting a non-idempotent
                  -- send and then echo it without returning an id.  Reconcile
                  -- only one recent exact-content candidate; ambiguity is safer
                  -- left for admin/status repair than guessed.
                  rows <-
                    query
                      "SELECT d.canonical_message_id FROM message_deliveries d \
                      \ JOIN messages m USING (canonical_message_id) \
                      \ WHERE d.endpoint_id = ? \
                      \   AND d.status IN ('sending', 'accepted_unconfirmed', 'outcome_unknown') \
                      \   AND d.created_at >= now() - interval '10 minutes' \
                      \   AND m.canonical_content = ? \
                      \ ORDER BY d.delivery_id DESC LIMIT 2 FOR UPDATE OF d"
                      (envelope.endpointId.unEndpointId, Jsonb contentValue)
                  pure $ case rows :: [Only Int64] of
                    [Only cid] -> Just cid
                    _ -> Nothing
              | otherwise -> pure Nothing
        _ -> error "ingestEnvelope: duplicate native delivery id invariant violated"
      forM candidate $ \cid -> do
        -- Every part writer locks the parent first, including reconciliation.
        parents <- query "SELECT delivery_id FROM message_deliveries WHERE canonical_message_id=? AND endpoint_id=? ORDER BY delivery_id FOR UPDATE" (cid, envelope.endpointId.unEndpointId)
        let _ = parents :: [Only Int64]
        _ <-
          execute
            "UPDATE message_delivery_parts p SET status='confirmed',updated_at=now() FROM message_deliveries d WHERE d.delivery_id=p.delivery_id AND d.endpoint_id=? AND d.canonical_message_id=? AND p.native_event_id=?"
            (envelope.endpointId.unEndpointId, cid, nativeEvent)
        _ <-
          execute
            "UPDATE message_deliveries d SET status='confirmed',confirmed_at=now(),updated_at=now() WHERE d.endpoint_id=? AND d.canonical_message_id=? AND d.status='accepted_unconfirmed' AND EXISTS (SELECT 1 FROM message_delivery_parts p WHERE p.delivery_id=d.delivery_id) AND NOT EXISTS (SELECT 1 FROM message_delivery_parts p WHERE p.delivery_id=d.delivery_id AND p.status<>'confirmed')"
            (envelope.endpointId.unEndpointId, cid)
        _ <-
          execute
            "UPDATE message_deliveries \
            \ SET status = 'confirmed', native_event_id = ?, confirmed_at = ?, \
            \     lease_owner = NULL, lease_expires_at = NULL, last_error = NULL, updated_at = now() \
            \ WHERE canonical_message_id = ? AND endpoint_id = ? \
            \ AND NOT EXISTS (SELECT 1 FROM message_delivery_parts p WHERE p.delivery_id=message_deliveries.delivery_id)"
            (nativeEvent, envelope.receivedAt, cid, envelope.endpointId.unEndpointId)
        _ <-
          execute
            "INSERT INTO platform_events \
            \ (endpoint_id, native_event_id, sender_identity_id, event_kind, occurred_at, received_at, \
            \  source_cursor, raw_payload, raw_payload_truncated, canonical_message_id, ingest_class) \
            \ VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) \
            \ ON CONFLICT (endpoint_id, native_event_id) DO NOTHING"
            ( envelope.endpointId.unEndpointId,
              nativeEvent,
              identityId,
              renderEventKind envelope.eventKind,
              envelope.occurredAt,
              envelope.receivedAt,
              Jsonb . unPlatformCursor <$> envelope.sourceCursor,
              Jsonb <$> safeRaw,
              rawTruncated,
              cid,
              renderIngestClass envelope.ingestClass
            )
        pure cid

    reconcileMetaEcho = case find isReaction envelope.relations of
      Just (ReactsTo (NativeEventId target) key action)
        | envelope.eventKind == EventReaction -> do
            resolved <- resolveNativeTarget envelope.endpointId target
            case resolved of
              Nothing -> pure Nothing
              Just targetCanonical -> do
                rows <-
                  query
                    "SELECT d.canonical_message_id FROM message_deliveries d \
                    \ JOIN messages m USING (canonical_message_id) \
                    \ JOIN message_relations relation USING (canonical_message_id) \
                    \ WHERE d.endpoint_id = ? AND m.message_origin = 'internal' \
                    \   AND m.event_kind = 'reaction' \
                    \   AND d.status IN ('sending', 'accepted_unconfirmed', 'outcome_unknown', 'confirmed') \
                    \   AND d.created_at >= now() - interval '10 minutes' \
                    \   AND relation.relation_kind = 'reaction' \
                    \   AND relation.target_canonical_message_id = ? \
                    \   AND relation.reaction_key = ? AND relation.reaction_added = ? \
                    \ ORDER BY d.delivery_id DESC LIMIT 2 FOR UPDATE OF d"
                    ( envelope.endpointId.unEndpointId,
                      targetCanonical,
                      key,
                      action == ReactionAdd
                    )
                pure $ case rows :: [Only Int64] of
                  [Only cid] -> Just cid
                  _ -> Nothing
      _ -> pure Nothing
      where
        isReaction ReactsTo {} = True
        isReaction _ = False

    insertCanonical endpoint identityId identities resolvedBody contentValue = do
      let platformName = endpoint.erPlatform
          NativeEventId nativeEvent = envelope.nativeEventId
          NativeUserId nativeUser = envelope.senderNativeId
          bodyProjection = promptCanonicalText (identityPrincipals identities) resolvedBody
          provenanceSegments
            | platformName == "qq" = fromMaybe (toJSON ([] :: [Value])) options.qqProvenanceSegments
            | otherwise = toJSON ([] :: [Value])
      legacySelf <- compatibilityId platformName "user" endpoint.erNativeAccountId
      legacyUser <- compatibilityId platformName "user" nativeUser
      legacyMessage <- compatibilityId platformName "message" nativeEvent
      legacyGroup <- case endpoint.erLegacyGroupId of
        Just gid -> pure gid
        Nothing -> error "ingestEnvelope: endpoint conversation lacks compatibility projection"
      replyTarget <- resolveReply envelope.endpointId envelope.relations
      -- A meta event's body is empty by construction, so its projection has
      -- to come from the relation instead.  Resolved here because this is
      -- already the transaction that turns native relation ids into canonical
      -- ones, and a row whose rendered_text is filled in later is a row that
      -- can be read blank in between.
      rendered <- metaProjection bodyProjection
      -- @sender_nickname@ falls back to the identity the batch just ensured,
      -- which the row is already joined against.  An event that carries no
      -- name of its own is normal, not exceptional: a QQ recall or reaction
      -- notice names only a user id.  Without the fallback those rows read
      -- back as a bare principal id, and one of them being a speaker's newest
      -- line is enough to put a number in the prompt roster.
      let replyLegacy = snd <$> replyTarget
          replyCanonical = fst <$> replyTarget
      inserted <-
        query
          "INSERT INTO messages \
          \ (message_id, group_id, user_id, self_id, received_at, occurred_at, \
          \  segments, canonical_content, rendered_text, raw_message, sender_nickname, \
          \  reply_to_message_id, reply_to_canonical_message_id, kind, conversation_id, \
          \  author_principal_id, origin_endpoint_id, source_native_event_id, message_origin, source_platform, event_kind, ingest_class) \
          \ SELECT ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, COALESCE(?, pi.display_name), ?, ?, ?, ?, \
          \        pi.principal_id, ?, ?, 'inbound', ?, ?, ? \
          \ FROM principal_identities pi WHERE pi.principal_identity_id = ? \
          \ RETURNING canonical_message_id, ingest_seq"
          ( ( legacyMessage,
              legacyGroup,
              legacyUser,
              legacySelf,
              envelope.receivedAt,
              envelope.occurredAt,
              Jsonb provenanceSegments,
              Jsonb contentValue,
              rendered,
              rendered,
              envelope.senderDisplayName,
              replyLegacy,
              replyCanonical,
              options.transcriptKind,
              endpoint.erConversationId,
              envelope.endpointId.unEndpointId,
              nativeEvent,
              platformName,
              renderEventKind envelope.eventKind,
              renderIngestClass envelope.ingestClass
            )
              :. Only identityId
          )
      let (cid, ingestSeq) = case inserted :: [(Int64, Int64)] of
            [row] -> row
            _ -> error "ingestEnvelope message: expected exactly one row"
      _ <-
        execute
          "UPDATE platform_events SET canonical_message_id = ? \
          \ WHERE endpoint_id = ? AND native_event_id = ?"
          (cid, envelope.endpointId.unEndpointId, nativeEvent)
      _ <-
        execute
          "INSERT INTO message_deliveries \
          \ (canonical_message_id, endpoint_id, status, native_event_id, idempotency_key, confirmed_at) \
          \ VALUES (?, ?, 'confirmed', ?, 'source:' || ?, ?)"
          (cid, envelope.endpointId.unEndpointId, nativeEvent, nativeEvent, envelope.receivedAt)
      let dispatchable = envelope.ingestClass == LiveDelivery && envelope.eventKind == EventMessage && options.createDispatch
      forM_ envelope.relations (insertRelation cid envelope.endpointId)
      -- The identity batch above always carries both the sender and Max's own
      -- account, so the lookups hold; resolving them totally keeps a monitor
      -- from being the reason an ordinary message fails to ingest, and an
      -- unresolvable principal simply declines to evaluate (fail closed).
      let monitorPrincipals = do
            (_, sender) <- Map.lookup envelope.senderNativeId identities
            (_, self) <- Map.lookup (NativeUserId endpoint.erNativeAccountId) identities
            pure (PrincipalId sender, PrincipalId self)
      when (envelope.ingestClass == LiveDelivery && envelope.eventKind == EventMessage) $
        forM_ monitorPrincipals $ \(senderPrincipal, selfPrincipal) -> do
          _ <-
            evaluateLedgerMatches
              endpoint.erConversationId
              ingestSeq
              (CanonicalMessageId cid)
              senderPrincipal
              selfPrincipal
              (identityPrincipals identities)
              rendered
              resolvedBody
              envelope.receivedAt
          pure ()
      _ <-
        if not options.createMirrorDeliveries
          then pure 0
          else case envelope.eventKind of
            -- Only what the transcript shows crosses to another platform.  A
            -- command is addressed to max, not to the room: nobody there typed
            -- it, nobody there can act on it, and every prompt reader already
            -- hides it.  Meta events stay mirrorable — a reaction or an edit
            -- is /about/ a message the other endpoints do hold.
            EventMessage
              | options.transcriptKind == renderMessageKind KindChat ->
                  insertMessageMirrors cid envelope.endpointId
              | otherwise -> pure 0
            EventEdit -> insertMetaMirrors cid envelope.endpointId ("replace" :: Text) ("edit" :: Text)
            EventReaction -> insertMetaMirrors cid envelope.endpointId ("reaction" :: Text) ("reaction" :: Text)
            EventRedaction -> insertMetaMirrors cid envelope.endpointId ("redacts" :: Text) ("redact" :: Text)
            EventMembership -> pure 0
      mirrors <- deliveryTargets (CanonicalMessageId cid)
      pure
        ( Ingested
            NewIngest
              { canonicalMessageId = CanonicalMessageId cid,
                canonicalBody = resolvedBody,
                dispatchEligible = dispatchable,
                mirrorDeliveries = mirrors
              }
        )

    -- \| An ordinary message projects its own body; anything else projects
    -- what it did to another message.  A meta event carries at most one such
    -- relation, and a reaction is the only one that also carries a key.
    metaProjection bodyProjection = case envelope.eventKind of
      EventMessage -> pure bodyProjection
      kind -> do
        let described = listToMaybe (mapMaybe describes envelope.relations)
        target <- traverse (resolveNativeTarget envelope.endpointId . fst) described
        pure $
          systemEventText
            kind
            (join target)
            (snd =<< described)
            (all metaAdded envelope.relations)
      where
        describes = \case
          Redacts (NativeEventId target) -> Just (target, Nothing)
          Replaces (NativeEventId target) -> Just (target, Nothing)
          ReactsTo (NativeEventId target) key _ -> Just (target, Just key)
          _ -> Nothing
        metaAdded = \case
          ReactsTo _ _ action -> action == ReactionAdd
          _ -> True

    insertMessageMirrors cid originEndpoint =
      execute
        "INSERT INTO message_deliveries \
        \ (canonical_message_id, endpoint_id, status, idempotency_key) \
        \ SELECT ?, target.endpoint_id, 'pending', \
        \        'relay:' || ?::text || ':' || target.endpoint_id::text \
        \ FROM conversation_endpoints origin \
        \ JOIN conversation_endpoints target \
        \   ON target.conversation_id = origin.conversation_id \
        \  AND target.endpoint_id <> origin.endpoint_id \
        \ JOIN platform_accounts target_account \
        \   ON target_account.platform_account_id = target.platform_account_id \
        \ WHERE origin.endpoint_id = ? \
        \   AND origin.endpoint_mode = 'mirror' \
        \   AND target.endpoint_mode = 'mirror' \
        \   AND target.enabled AND target_account.enabled \
        \ ON CONFLICT (canonical_message_id, endpoint_id) DO NOTHING"
        (cid, cid, originEndpoint.unEndpointId)

    insertMetaMirrors cid originEndpoint relationKind capabilityKey = do
      candidates <-
        query
          "SELECT target.endpoint_id, \
          \       CASE WHEN target.capabilities = '{}'::jsonb \
          \            THEN target_account.capabilities ELSE target.capabilities END \
          \ FROM conversation_endpoints origin \
          \ JOIN conversation_endpoints target \
          \   ON target.conversation_id = origin.conversation_id \
          \  AND target.endpoint_id <> origin.endpoint_id \
          \ JOIN platform_accounts target_account \
          \   ON target_account.platform_account_id = target.platform_account_id \
          \ JOIN message_relations relation \
          \   ON relation.canonical_message_id = ? \
          \  AND relation.relation_kind = ? \
          \  AND relation.target_canonical_message_id IS NOT NULL \
          \ WHERE origin.endpoint_id = ? \
          \   AND origin.endpoint_mode = 'mirror' \
          \   AND target.endpoint_mode = 'mirror' \
          \   AND target.enabled AND target_account.enabled \
          \   AND ( \
          \     EXISTS (SELECT 1 FROM platform_events copy \
          \             WHERE copy.endpoint_id = target.endpoint_id \
          \               AND copy.canonical_message_id = relation.target_canonical_message_id) \
          \     OR EXISTS (SELECT 1 FROM message_deliveries copy \
          \                WHERE copy.endpoint_id = target.endpoint_id \
          \                  AND copy.canonical_message_id = relation.target_canonical_message_id \
          \                  AND copy.native_event_id IS NOT NULL) \
          \   ) \
          \ ORDER BY target.endpoint_id"
          (cid, relationKind, originEndpoint.unEndpointId)
      let endpointIds =
            PGArray
              [ endpoint
              | (endpoint, manifest) <- (candidates :: [(Int64, Value)]),
                metaCapabilityEnabled capabilityKey (outboundCapsFromValue manifest)
              ]
      execute
        "INSERT INTO message_deliveries \
        \ (canonical_message_id, endpoint_id, status, idempotency_key) \
        \ SELECT ?, target.endpoint_id, 'pending', \
        \        'relay:' || ?::text || ':' || target.endpoint_id::text \
        \ FROM unnest(?::bigint[]) AS target(endpoint_id) \
        \ ON CONFLICT (canonical_message_id, endpoint_id) DO NOTHING"
        (cid, cid, endpointIds)

readIngestCursor ::
  (WithConnection :> es, IOE :> es) =>
  PlatformAccountId ->
  Text ->
  Eff es (Maybe CursorRecord)
readIngestCursor (PlatformAccountId accountId) streamKey = do
  rows <-
    query
      "SELECT cursor, source_fingerprint, revision FROM platform_ingest_cursors \
      \ WHERE platform_account_id = ? AND stream_key = ?"
      (accountId, streamKey)
  pure $ case rows :: [(Value, Maybe Text, Int64)] of
    [(value, sourceFingerprint, cursorRevision)] ->
      Just (CursorRecord (PlatformCursor value) sourceFingerprint cursorRevision)
    _ -> Nothing

-- | Advance only from the version the adapter actually consumed.  @Nothing@
-- means the stream must not exist yet; stale workers cannot skip a page.
advanceIngestCursorCAS ::
  (WithConnection :> es, IOE :> es) =>
  PlatformAccountId ->
  Text ->
  Maybe Int64 ->
  PlatformCursor ->
  Maybe Text ->
  Eff es (Maybe CursorRecord)
advanceIngestCursorCAS (PlatformAccountId accountId) streamKey expected (PlatformCursor next) sourceFingerprint = do
  rows <- case expected of
    Nothing ->
      query
        "INSERT INTO platform_ingest_cursors \
        \ (platform_account_id, stream_key, cursor, source_fingerprint) \
        \ VALUES (?, ?, ?, ?) \
        \ ON CONFLICT DO NOTHING \
        \ RETURNING cursor, source_fingerprint, revision"
        (accountId, streamKey, Jsonb next, sourceFingerprint)
    Just expectedRevision ->
      query
        "UPDATE platform_ingest_cursors \
        \ SET cursor = ?, source_fingerprint = ?, revision = revision + 1, updated_at = now() \
        \ WHERE platform_account_id = ? AND stream_key = ? AND revision = ? \
        \ RETURNING cursor, source_fingerprint, revision"
        (Jsonb next, sourceFingerprint, accountId, streamKey, expectedRevision)
  pure $ case rows :: [(Value, Maybe Text, Int64)] of
    [(value, fingerprint', revision')] -> Just (CursorRecord (PlatformCursor value) fingerprint' revision')
    _ -> Nothing

-- | Read a canonical message for live ingress or an explicit job/reminder.
-- This query has no ownership or restart-continuation semantics.
loadDispatchMessage :: (WithConnection :> es, IOE :> es) => CanonicalMessageId -> Eff es (Maybe DispatchMessage)
loadDispatchMessage (CanonicalMessageId canonical) = do
  rows <-
    query
      "SELECT m.canonical_message_id, m.group_id, m.user_id, m.self_id, \
      \       m.author_principal_id, self_identity.principal_id, m.canonical_content, \
      \       m.reply_to_canonical_message_id, m.source_platform, m.sender_nickname \
      \ FROM messages m \
      \ JOIN conversation_endpoints origin_endpoint ON origin_endpoint.endpoint_id = m.origin_endpoint_id \
      \ JOIN platform_accounts origin_account USING (platform_account_id) \
      \ JOIN principal_identities self_identity \
      \   ON self_identity.platform_account_id = origin_endpoint.platform_account_id \
      \  AND self_identity.native_user_id = origin_account.native_account_id \
      \ WHERE m.canonical_message_id = ?"
      (Only canonical)
  forM (listToMaybe (rows :: [DispatchRow])) $ \row -> do
    principals <- mentionPrincipalsFor (mentionIdentities row.drBody)
    pure
      DispatchMessage
        { canonicalId = CanonicalMessageId row.drCanonical,
          groupId = GroupId row.drGroup,
          userId = UserId row.drUser,
          selfId = UserId row.drSelf,
          authorPrincipalId = PrincipalId row.drAuthor,
          selfPrincipalId = PrincipalId row.drSelfPrincipal,
          body = row.drBody,
          replyTo = CanonicalMessageId <$> row.drReply,
          sourcePlatform = parsePlatform row.drPlatform,
          senderDisplayName = row.drName,
          mentionPrincipals = principals
        }

sanitizeIngestOptions :: IngestOptions -> IngestOptions
sanitizeIngestOptions options =
  options
    { transcriptKind = sanitizePostgresText options.transcriptKind,
      qqProvenanceSegments = sanitizePostgresValue <$> options.qqProvenanceSegments
    }

renderIngestClass :: IngestClass -> Text
renderIngestClass = \case
  LiveDelivery -> "live_delivery"
  Backfill -> "backfill"
