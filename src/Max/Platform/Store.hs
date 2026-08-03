{-# LANGUAGE DeriveGeneric #-}

-- | Transactional canonical ingest, cursor and delivery kernel shared by all
-- platform adapters.
--
-- Adapters normalize protocol traffic into 'InboundEnvelope'.  This module is
-- the only place that turns it into durable conversation state: native-event
-- dedupe, canonical message insertion, source confirmation, mirror outbox and
-- dispatch publication commit together.
module Max.Platform.Store
  ( EndpointRegistration (..),
    RegisteredEndpoint (..),
    createConversation,
    findConversationByLegacyId,
    registerEndpoint,
    IngestResult (..),
    NewIngest (..),
    ingestEnvelope,
    CursorRecord (..),
    readIngestCursor,
    advanceIngestCursorCAS,
    DeliveryClaim (..),
    claimDeliveries,
    DeliveryCompletion (..),
    completeDelivery,
    sanitizeRawPayload,
    canonicalContentValue,
    renderCanonicalText,
  )
where

import Control.Monad (forM_)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.Aeson
  ( KeyValue ((.=)),
    Value (..),
    encode,
    object,
    toJSON,
  )
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Base16 qualified as Base16
import Data.ByteString.Lazy qualified as LBS
import Data.Int (Int64)
import Data.List (find)
import Data.Maybe (fromMaybe, listToMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (NominalDiffTime, UTCTime)
import Database.PostgreSQL.Simple.FromRow (FromRow (..), field)
import Database.PostgreSQL.Simple.ToField (ToField (..), toJSONField)
import Database.PostgreSQL.Simple.Types (Only (..))
import Effectful
import Effectful.PostgreSQL (WithConnection, execute, query, withTransaction)
import GHC.Generics (Generic)
import Max.Platform.Types
import Text.Read (readMaybe)

newtype Jsonb = Jsonb Value

instance ToField Jsonb where
  toField (Jsonb value) = toJSONField value

data EndpointRegistration = EndpointRegistration
  { conversationId :: !ConversationId,
    platform :: !Platform,
    nativeAccountId :: !NativeAccountId,
    accountDisplayName :: !(Maybe Text),
    nativeConversationId :: !NativeConversationId,
    endpointDisplayName :: !(Maybe Text),
    conversationKind :: !ConversationKind,
    endpointMode :: !EndpointMode,
    capabilities :: !PlatformCapabilities
  }
  deriving stock (Eq, Show, Generic)

data RegisteredEndpoint = RegisteredEndpoint
  { endpointId :: !EndpointId,
    platformAccountId :: !PlatformAccountId,
    conversationId :: !ConversationId
  }
  deriving stock (Eq, Show, Generic)

data IngestResult
  = Ingested !NewIngest
  | AlreadyIngested !CanonicalMessageId
  deriving stock (Eq, Show, Generic)

data NewIngest = NewIngest
  { canonicalMessageId :: !CanonicalMessageId,
    dispatchCreated :: !Bool,
    mirrorDeliveriesCreated :: !Int64
  }
  deriving stock (Eq, Show, Generic)

data CursorRecord = CursorRecord
  { cursor :: !PlatformCursor,
    fingerprint :: !(Maybe Text),
    revision :: !Int64
  }
  deriving stock (Eq, Show, Generic)

data DeliveryClaim = DeliveryClaim
  { deliveryId :: !DeliveryId,
    canonicalMessageId :: !CanonicalMessageId,
    endpointId :: !EndpointId,
    platform :: !Platform,
    nativeAccountId :: !NativeAccountId,
    nativeConversationId :: !NativeConversationId,
    content :: !Value,
    idempotencyKey :: !Text,
    attemptCount :: !Int,
    capabilities :: !Value
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

data EndpointRow = EndpointRow
  { erConversationId :: !Int64,
    erPlatformAccountId :: !Int64,
    erPlatform :: !Text,
    erNativeAccountId :: !Text,
    erLegacyGroupId :: !(Maybe Int64)
  }

instance FromRow EndpointRow where
  fromRow = EndpointRow <$> field <*> field <*> field <*> field <*> field

data DeliveryClaimRow = DeliveryClaimRow
  { dcDeliveryId :: !Int64,
    dcCanonicalMessageId :: !Int64,
    dcEndpointId :: !Int64,
    dcPlatform :: !Text,
    dcNativeAccountId :: !Text,
    dcNativeConversationId :: !Text,
    dcContent :: !Value,
    dcIdempotencyKey :: !Text,
    dcAttemptCount :: !Int,
    dcCapabilities :: !Value
  }

instance FromRow DeliveryClaimRow where
  fromRow =
    DeliveryClaimRow <$> field <*> field <*> field <*> field <*> field <*> field <*> field <*> field <*> field <*> field

createConversation ::
  (WithConnection :> es, IOE :> es) =>
  ConversationKind ->
  Maybe Text ->
  Eff es ConversationId
createConversation kind title = do
  rows <-
    query
      "INSERT INTO conversations (conversation_kind, title) VALUES (?, ?) RETURNING conversation_id"
      (renderConversationKind kind, title)
  case rows of
    [Only cid] -> pure (ConversationId cid)
    _ -> error "createConversation: INSERT did not return one row"

findConversationByLegacyId ::
  (WithConnection :> es, IOE :> es) =>
  Int64 ->
  Eff es (Maybe ConversationId)
findConversationByLegacyId legacyId = do
  rows <- query "SELECT conversation_id FROM conversations WHERE legacy_group_id = ?" (Only legacyId)
  pure (ConversationId . fromOnly <$> listToMaybe rows)

registerEndpoint ::
  (WithConnection :> es, IOE :> es) =>
  EndpointRegistration ->
  Eff es RegisteredEndpoint
registerEndpoint registration = withTransaction $ do
  let platformName = renderPlatform registration.platform
      NativeAccountId nativeAccount = registration.nativeAccountId
      NativeConversationId nativeConversation = registration.nativeConversationId
      capabilities = Jsonb (capabilitiesValue registration.capabilities)
  accountRows <-
    query
      "INSERT INTO platform_accounts \
      \ (platform, native_account_id, display_name, capabilities) \
      \ VALUES (?, ?, ?, ?) \
      \ ON CONFLICT (platform, native_account_id) DO UPDATE \
      \ SET display_name = COALESCE(EXCLUDED.display_name, platform_accounts.display_name), \
      \     capabilities = EXCLUDED.capabilities, updated_at = now() \
      \ RETURNING platform_account_id"
      (platformName, nativeAccount, registration.accountDisplayName, capabilities)
  let accountId = exactlyOne "registerEndpoint account" accountRows

  -- Canonical conversations no longer require a bigint identity.  The old
  -- query path still does, so allocate an explicit compatibility projection
  -- once; it is never consulted for routing or authorization.
  legacyRows <-
    query
      "SELECT legacy_group_id FROM conversations WHERE conversation_id = ? FOR UPDATE"
      (Only registration.conversationId.unConversationId)
  legacyGroup <- case legacyRows :: [Only (Maybe Int64)] of
    [Only (Just gid)] -> pure gid
    [Only Nothing] -> do
      projected <- compatibilityId platformName "channel" nativeConversation
      _ <-
        execute
          "UPDATE conversations SET legacy_group_id = ? WHERE conversation_id = ?"
          (projected, registration.conversationId.unConversationId)
      pure projected
    _ -> error "registerEndpoint: conversation does not exist"
  let _compatibilityOnly = legacyGroup

  endpointRows <-
    query
      "INSERT INTO conversation_endpoints \
      \ (conversation_id, platform_account_id, native_conversation_id, endpoint_kind, \
      \  endpoint_mode, display_name, capabilities) \
      \ VALUES (?, ?, ?, ?, ?, ?, ?) \
      \ ON CONFLICT (platform_account_id, native_conversation_id) DO UPDATE \
      \ SET conversation_id = EXCLUDED.conversation_id, endpoint_kind = EXCLUDED.endpoint_kind, \
      \     endpoint_mode = EXCLUDED.endpoint_mode, display_name = EXCLUDED.display_name, \
      \     capabilities = EXCLUDED.capabilities, updated_at = now() \
      \ RETURNING endpoint_id"
      ( registration.conversationId.unConversationId,
        accountId,
        nativeConversation,
        renderConversationKind registration.conversationKind,
        renderEndpointMode registration.endpointMode,
        registration.endpointDisplayName,
        capabilities
      )
  let endpoint = exactlyOne "registerEndpoint endpoint" endpointRows
  pure
    RegisteredEndpoint
      { endpointId = EndpointId endpoint,
        platformAccountId = PlatformAccountId accountId,
        conversationId = registration.conversationId
      }

-- | Persist one normalized event exactly once.  The unique native event key is
-- reserved before any canonical row is inserted, and all derived work is
-- published in the same transaction.
ingestEnvelope ::
  (WithConnection :> es, IOE :> es) =>
  Int -> -- ^ maximum persisted diagnostic raw-payload bytes
  InboundEnvelope ->
  Eff es IngestResult
ingestEnvelope maxRawBytes envelope = withTransaction $ do
  endpoint <- fetchEndpoint envelope.endpointId
  identityId <- ensurePrincipalIdentity endpoint envelope.senderNativeId envelope.senderDisplayName
  let NativeEventId nativeEvent = envelope.nativeEventId
      (safeRaw, rawTruncated) = sanitizeRawPayload maxRawBytes envelope.rawPayload
  reserved <-
    query
      "INSERT INTO platform_events \
      \ (endpoint_id, native_event_id, sender_identity_id, event_kind, occurred_at, \
      \  received_at, source_cursor, raw_payload, raw_payload_truncated) \
      \ VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) \
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
        rawTruncated
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
        _ -> error "ingestEnvelope: committed platform event has no canonical message"
    [_] -> insertCanonical endpoint identityId safeRaw
    _ -> error "ingestEnvelope: event reservation returned multiple rows"
  where
    insertCanonical endpoint identityId _safeRaw = do
      let platformName = endpoint.erPlatform
          NativeEventId nativeEvent = envelope.nativeEventId
          NativeUserId nativeUser = envelope.senderNativeId
          contentValue = canonicalContentValue envelope.content
          rendered = renderCanonicalText envelope.content
      legacySelf <- compatibilityId platformName "user" endpoint.erNativeAccountId
      legacyUser <- compatibilityId platformName "user" nativeUser
      legacyMessage <- compatibilityId platformName "message" nativeEvent
      legacyGroup <- case endpoint.erLegacyGroupId of
        Just gid -> pure gid
        Nothing -> error "ingestEnvelope: endpoint conversation lacks compatibility projection"
      replyTarget <- resolveReply envelope.endpointId envelope.relations
      let replyLegacy = snd <$> replyTarget
          replyCanonical = fst <$> replyTarget
      inserted <-
        query
          "INSERT INTO messages \
          \ (message_id, group_id, user_id, self_id, received_at, occurred_at, \
          \  segments, canonical_content, rendered_text, raw_message, sender_nickname, \
          \  reply_to_message_id, reply_to_canonical_message_id, kind, conversation_id, \
          \  author_principal_id, origin_endpoint_id, source_native_event_id) \
          \ SELECT ?, ?, ?, ?, ?, ?, '[]'::jsonb, ?, ?, '', ?, ?, ?, 'chat', ?, \
          \        pi.principal_id, ?, ? \
          \ FROM principal_identities pi WHERE pi.principal_identity_id = ? \
          \ RETURNING canonical_message_id"
          ( legacyMessage,
            legacyGroup,
            legacyUser,
            legacySelf,
            envelope.receivedAt,
            envelope.occurredAt,
            Jsonb contentValue,
            rendered,
            envelope.senderDisplayName,
            replyLegacy,
            replyCanonical,
            endpoint.erConversationId,
            envelope.endpointId.unEndpointId,
            nativeEvent,
            identityId
          )
      let cid = exactlyOne "ingestEnvelope message" inserted
      _ <-
        execute
          "UPDATE platform_events SET canonical_message_id = ? \
          \ WHERE endpoint_id = ? AND native_event_id = ?"
          (cid, envelope.endpointId.unEndpointId, nativeEvent)
      -- The compatibility AFTER trigger records completed; normalized ingest
      -- is durable work and intentionally turns it into pending.
      dispatchCount <-
        execute
          "UPDATE message_dispatches SET status = 'pending', updated_at = now() \
          \ WHERE canonical_message_id = ?"
          (Only cid)
      mirrorCount <-
        execute
          "INSERT INTO message_deliveries \
          \ (canonical_message_id, endpoint_id, status, idempotency_key) \
          \ SELECT ?, target.endpoint_id, 'pending', \
          \        'relay:' || ?::text || ':' || target.endpoint_id::text \
          \ FROM conversation_endpoints origin \
          \ JOIN conversation_endpoints target \
          \   ON target.conversation_id = origin.conversation_id \
          \  AND target.endpoint_id <> origin.endpoint_id \
          \ WHERE origin.endpoint_id = ? \
          \   AND origin.endpoint_mode = 'mirror' \
          \   AND target.endpoint_mode = 'mirror' \
          \   AND target.enabled \
          \ ON CONFLICT (canonical_message_id, endpoint_id) DO NOTHING"
          (cid, cid, envelope.endpointId.unEndpointId)
      forM_ envelope.relations (insertRelation cid envelope.endpointId)
      pure
        ( Ingested
            NewIngest
            { canonicalMessageId = CanonicalMessageId cid,
              dispatchCreated = dispatchCount == 1,
              mirrorDeliveriesCreated = mirrorCount
            }
        )

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

claimDeliveries ::
  (WithConnection :> es, IOE :> es) =>
  Text -> -- ^ stable worker id
  Int ->
  NominalDiffTime ->
  Eff es [DeliveryClaim]
claimDeliveries workerId limit leaseDuration = do
  rows <-
    query
      "WITH candidates AS ( \
      \ SELECT d.delivery_id FROM message_deliveries d \
      \ JOIN conversation_endpoints e ON e.endpoint_id = d.endpoint_id AND e.enabled \
      \ JOIN platform_accounts a ON a.platform_account_id = e.platform_account_id AND a.enabled \
      \ WHERE d.status IN ('pending', 'failed', 'outcome_unknown') \
      \   AND d.next_attempt_at <= now() \
      \   AND (d.lease_expires_at IS NULL OR d.lease_expires_at < now()) \
      \ ORDER BY d.next_attempt_at, d.delivery_id \
      \ FOR UPDATE OF d SKIP LOCKED LIMIT ? \
      \), claimed AS ( \
      \ UPDATE message_deliveries d \
      \ SET status = 'sending', lease_owner = ?, \
      \     lease_expires_at = now() + (?::double precision * interval '1 second'), \
      \     attempt_count = attempt_count + 1, last_attempt_at = now(), updated_at = now() \
      \ FROM candidates c WHERE d.delivery_id = c.delivery_id \
      \ RETURNING d.* \
      \) \
      \ SELECT c.delivery_id, c.canonical_message_id, c.endpoint_id, a.platform, \
      \        a.native_account_id, e.native_conversation_id, m.canonical_content, \
      \        c.idempotency_key, c.attempt_count, \
      \        CASE WHEN e.capabilities = '{}'::jsonb THEN a.capabilities ELSE e.capabilities END \
      \ FROM claimed c \
      \ JOIN conversation_endpoints e ON e.endpoint_id = c.endpoint_id \
      \ JOIN platform_accounts a ON a.platform_account_id = e.platform_account_id \
      \ JOIN messages m ON m.canonical_message_id = c.canonical_message_id \
      \ ORDER BY c.delivery_id"
      (limit, workerId, realToFrac leaseDuration :: Double)
  pure (toClaim <$> (rows :: [DeliveryClaimRow]))

completeDelivery ::
  (WithConnection :> es, IOE :> es) =>
  Text ->
  DeliveryId ->
  DeliveryCompletion ->
  Eff es Bool
completeDelivery workerId (DeliveryId delivery) completion = do
  changed <- case completion of
    DeliveryConfirmedAs native ->
      finish ("confirmed" :: Text) native Nothing Nothing True
    DeliveryAccepted native ->
      finish "accepted_unconfirmed" native Nothing Nothing False
    DeliveryRetry err next ->
      finish "failed" Nothing (Just err) (Just next) False
    DeliveryUnknown err next ->
      finish "outcome_unknown" Nothing (Just err) (Just next) False
    DeliveryPermanentlyFailed err ->
      finish "suppressed" Nothing (Just err) Nothing False
    DeliverySuppressedAs reason ->
      finish "suppressed" Nothing (Just reason) Nothing False
  pure (changed == 1)
  where
    finish status native lastError next confirmed =
      execute
        "UPDATE message_deliveries \
        \ SET status = ?, native_event_id = COALESCE(?, native_event_id), \
        \     last_error = ?, next_attempt_at = COALESCE(?, next_attempt_at), \
        \     confirmed_at = CASE WHEN ? THEN now() ELSE confirmed_at END, \
        \     lease_owner = NULL, lease_expires_at = NULL, updated_at = now() \
        \ WHERE delivery_id = ? AND status = 'sending' AND lease_owner = ?"
        ( status,
          unNativeEventId <$> native,
          lastError,
          next,
          confirmed,
          delivery,
          workerId
        )

sanitizeRawPayload :: Int -> Maybe Value -> (Maybe Value, Bool)
sanitizeRawPayload _ Nothing = (Nothing, False)
sanitizeRawPayload maxBytes (Just raw) =
  let sanitized = redact raw
      bytes = encode sanitized
      size = LBS.length bytes
   in if size <= fromIntegral (max 0 maxBytes)
        then (Just sanitized, False)
        else
          ( Just
              ( object
                  [ "truncated" .= True,
                    "sanitized_bytes" .= size,
                    "sha256" .= TE.decodeUtf8 (Base16.encode (SHA256.hashlazy bytes))
                  ]
              ),
            True
          )
  where
    redact = \case
      Object values -> Object (KeyMap.mapWithKey redactField values)
      Array values -> Array (fmap redact values)
      other -> other
    redactField key value
      | isSecretKey (Key.toText key) = String "[redacted]"
      | otherwise = redact value
    isSecretKey =
      (`elem` ["token", "access_token", "password", "authorization", "secret", "cookie", "admin_key"])
        . T.toLower

canonicalContentValue :: [ContentPart] -> Value
canonicalContentValue parts =
  toArray (partValue <$> parts)
  where
    toArray = toJSON
    partValue = \case
      ContentText body -> object ["type" .= ("text" :: Text), "text" .= body]
      ContentMention (NativeUserId user) display ->
        object ["type" .= ("mention" :: Text), "native_user_id" .= user, "display" .= display]
      ContentMedia source caption ->
        object ["type" .= ("media" :: Text), "source" .= mediaValue source, "caption" .= caption]
      ContentUnsupported description ->
        object ["type" .= ("unsupported" :: Text), "description" .= description]
    mediaValue = \case
      RemoteMedia url mime size sha ->
        object
          [ "kind" .= ("remote" :: Text),
            "url" .= url,
            "mime_type" .= mime,
            "size" .= size,
            "sha256" .= sha
          ]
      InlineMedia bytes mime sha ->
        object
          [ "kind" .= ("inline" :: Text),
            "bytes" .= TE.decodeUtf8 (Base16.encode bytes),
            "mime_type" .= mime,
            "sha256" .= sha
          ]

renderCanonicalText :: [ContentPart] -> Text
renderCanonicalText = T.intercalate " " . fmap render
  where
    render = \case
      ContentText body -> body
      ContentMention (NativeUserId user) display -> "@" <> fromMaybe user display
      ContentMedia _ caption -> fromMaybe "[media]" caption
      ContentUnsupported description -> "[unsupported: " <> description <> "]"

fetchEndpoint ::
  (WithConnection :> es, IOE :> es) =>
  EndpointId ->
  Eff es EndpointRow
fetchEndpoint (EndpointId endpoint) = do
  rows <-
    query
      "SELECT e.conversation_id, e.platform_account_id, a.platform, a.native_account_id, \
      \       c.legacy_group_id \
      \FROM conversation_endpoints e \
      \JOIN platform_accounts a USING (platform_account_id) \
      \JOIN conversations c USING (conversation_id) \
      \WHERE e.endpoint_id = ? AND e.enabled AND a.enabled"
      (Only endpoint)
  case rows of
    [row] -> pure row
    _ -> error "ingestEnvelope: unknown or disabled endpoint"

ensurePrincipalIdentity ::
  (WithConnection :> es, IOE :> es) =>
  EndpointRow ->
  NativeUserId ->
  Maybe Text ->
  Eff es Int64
ensurePrincipalIdentity endpoint (NativeUserId nativeUser) display = do
  existing <-
    query
      "SELECT principal_identity_id FROM principal_identities \
      \ WHERE platform_account_id = ? AND native_user_id = ? FOR UPDATE"
      (endpoint.erPlatformAccountId, nativeUser)
  case existing of
    [Only identity] -> pure identity
    [] -> do
      principalRows <-
        query
          "INSERT INTO principals (display_name) VALUES (?) RETURNING principal_id"
          (Only display)
      let principal = exactlyOne "ensurePrincipalIdentity principal" (principalRows :: [Only Int64])
      inserted <-
        query
          "INSERT INTO principal_identities \
          \ (principal_id, platform_account_id, native_user_id, display_name) \
          \ VALUES (?, ?, ?, ?) \
          \ ON CONFLICT (platform_account_id, native_user_id) DO NOTHING \
          \ RETURNING principal_identity_id"
          (principal, endpoint.erPlatformAccountId, nativeUser, display)
      case (inserted :: [Only Int64]) of
        [Only identity] -> pure identity
        [] -> do
          _ <- execute "DELETE FROM principals WHERE principal_id = ?" (Only principal)
          winner <-
            query
              "SELECT principal_identity_id FROM principal_identities \
              \ WHERE platform_account_id = ? AND native_user_id = ?"
              (endpoint.erPlatformAccountId, nativeUser)
          pure (exactlyOne "ensurePrincipalIdentity winner" winner)
        _ -> error "ensurePrincipalIdentity: multiple inserted identities"
    _ -> error "ensurePrincipalIdentity: duplicate identity invariant violated"

compatibilityId ::
  (WithConnection :> es, IOE :> es) =>
  Text ->
  Text ->
  Text ->
  Eff es Int64
compatibilityId platformName kind native =
  case platformName of
    "qq" | Just numeric <- readMaybe (T.unpack native) -> pure numeric
    _ -> do
      rows <-
        query
          "INSERT INTO platform_ids (platform, kind, native_id) VALUES (?, ?, ?) \
          \ ON CONFLICT (platform, kind, native_id) DO UPDATE SET native_id = EXCLUDED.native_id \
          \ RETURNING mapped_id"
          (platformName, kind, native)
      pure (exactlyOne "compatibilityId" rows)

resolveReply ::
  (WithConnection :> es, IOE :> es) =>
  EndpointId ->
  [MessageRelation] ->
  Eff es (Maybe (Int64, Int64))
resolveReply (EndpointId endpoint) relations = case find isReply relations of
  Just (ReplyTo (NativeEventId nativeTarget)) -> do
    rows <-
      query
        "SELECT m.canonical_message_id, m.message_id \
        \ FROM platform_events pe \
        \ JOIN messages m USING (canonical_message_id) \
        \ WHERE pe.endpoint_id = ? AND pe.native_event_id = ? \
        \ UNION ALL \
        \ SELECT m.canonical_message_id, m.message_id \
        \ FROM message_deliveries d \
        \ JOIN messages m USING (canonical_message_id) \
        \ WHERE d.endpoint_id = ? AND d.native_event_id = ? \
        \ LIMIT 1"
        (endpoint, nativeTarget, endpoint, nativeTarget)
    pure (listToMaybe rows)
  _ -> pure Nothing
  where
    isReply (ReplyTo _) = True
    isReply _ = False

insertRelation ::
  (WithConnection :> es, IOE :> es) =>
  Int64 ->
  EndpointId ->
  MessageRelation ->
  Eff es ()
insertRelation cid endpoint relation = do
  let (kind, targetNative, reaction) = case relation of
        ReplyTo (NativeEventId target) -> ("reply" :: Text, target, Nothing)
        Replaces (NativeEventId target) -> ("replace", target, Nothing)
        ReactsTo (NativeEventId target) key -> ("reaction", target, Just key)
  resolved <- resolveNativeTarget endpoint targetNative
  _ <-
    execute
      "INSERT INTO message_relations \
      \ (canonical_message_id, relation_kind, target_canonical_message_id, target_native_event_id, reaction_key) \
      \ VALUES (?, ?, ?, ?, ?) ON CONFLICT DO NOTHING"
      (cid, kind, resolved, targetNative, reaction)
  pure ()

resolveNativeTarget ::
  (WithConnection :> es, IOE :> es) =>
  EndpointId ->
  Text ->
  Eff es (Maybe Int64)
resolveNativeTarget (EndpointId endpoint) target = do
  rows <-
    query
      "SELECT canonical_message_id FROM platform_events \
      \ WHERE endpoint_id = ? AND native_event_id = ? AND canonical_message_id IS NOT NULL \
      \ UNION ALL \
      \ SELECT canonical_message_id FROM message_deliveries \
      \ WHERE endpoint_id = ? AND native_event_id = ? \
      \ LIMIT 1"
      (endpoint, target, endpoint, target)
  pure (fromOnly <$> listToMaybe rows)

exactlyOne :: String -> [Only a] -> a
exactlyOne _ [Only value] = value
exactlyOne label _ = error (label <> ": expected exactly one row")

toClaim :: DeliveryClaimRow -> DeliveryClaim
toClaim row =
  DeliveryClaim
    { deliveryId = DeliveryId row.dcDeliveryId,
      canonicalMessageId = CanonicalMessageId row.dcCanonicalMessageId,
      endpointId = EndpointId row.dcEndpointId,
      platform = parsePlatform row.dcPlatform,
      nativeAccountId = NativeAccountId row.dcNativeAccountId,
      nativeConversationId = NativeConversationId row.dcNativeConversationId,
      content = row.dcContent,
      idempotencyKey = row.dcIdempotencyKey,
      attemptCount = row.dcAttemptCount,
      capabilities = row.dcCapabilities
    }

renderConversationKind :: ConversationKind -> Text
renderConversationKind = \case
  ConversationGroup -> "group"
  ConversationDirect -> "direct"

renderEndpointMode :: EndpointMode -> Text
renderEndpointMode = \case
  EndpointStandalone -> "standalone"
  EndpointMirror -> "mirror"

renderEventKind :: EventKind -> Text
renderEventKind = \case
  EventMessage -> "message"
  EventEdit -> "edit"
  EventReaction -> "reaction"
  EventRedaction -> "redaction"
  EventMembership -> "membership"

capabilitiesValue :: PlatformCapabilities -> Value
capabilitiesValue capabilities =
  object
    [ "send_text" .= capabilities.canSendText,
      "send_media" .= capabilities.canSendMedia,
      "reply" .= capabilities.canReply,
      "edit" .= capabilities.canEdit,
      "reaction" .= capabilities.canReact,
      "redact" .= capabilities.canRedact,
      "max_text_bytes" .= capabilities.maxTextBytes
    ]
