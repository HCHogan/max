{-# LANGUAGE DeriveAnyClass #-}
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
    platformForLegacyConversation,
    platformForLegacyMessage,
    conversationOutputCapabilities,
    compatibilityPlatformId,
    isBotAuthoredCompatibilityMessage,
    registerEndpoint,
    ensureLegacyEndpoint,
    ensureConfiguredEndpoint,
    latestNativeEventId,
    IngestOptions (..),
    defaultIngestOptions,
    IngestResult (..),
    NewIngest (..),
    ingestEnvelope,
    DispatchClaim (..),
    DispatchCompletion (..),
    claimDispatches,
    claimDispatch,
    completeDispatch,
    OutboundDraft (..),
    EnqueuedOutbound (..),
    enqueueOutbound,
    CursorRecord (..),
    readIngestCursor,
    advanceIngestCursorCAS,
    DeliveryClaim (..),
    claimDeliveries,
    claimDelivery,
    DeliveryCompletion (..),
    completeDelivery,
    UnconfirmedDelivery (..),
    listUnconfirmedDeliveries,
    confirmUnconfirmedDelivery,
    retryUnconfirmedDelivery,
    PlatformEndpointStatus (..),
    listPlatformStatus,
    sanitizeRawPayload,
    canonicalContentValue,
    renderCanonicalText,
  )
where

import Control.Monad (forM, forM_)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.Aeson
  ( KeyValue ((.=)),
    ToJSON,
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
import Effectful.PostgreSQL (WithConnection, execute, query)
import GHC.Generics (Generic)
import Max.DB.Transaction (withTransaction)
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
    conversationId :: !ConversationId,
    compatibilityConversationId :: !Int64
  }
  deriving stock (Eq, Show, Generic)

-- | Intersect the enabled endpoints' semantic output surface.  One canonical
-- reply can fan out to all of them, so advertising a feature supported by only
-- one endpoint would make the prompt promise a delivery the ledger cannot
-- preserve.  QQ mentions/faces are protocol-native and therefore require an
-- all-QQ conversation in addition to the ordinary capability flags.
conversationOutputCapabilities ::
  (WithConnection :> es, IOE :> es) =>
  Int64 ->
  Eff es ConversationOutputCapabilities
conversationOutputCapabilities legacyConversation = do
  rows <-
    query
      "WITH enabled AS ( \
      \ SELECT a.platform, CASE WHEN e.capabilities = '{}'::jsonb THEN a.capabilities ELSE e.capabilities END AS caps \
      \ FROM conversations c \
      \ JOIN conversation_endpoints e USING (conversation_id) \
      \ JOIN platform_accounts a USING (platform_account_id) \
      \ WHERE c.legacy_group_id = ? AND e.enabled AND a.enabled \
      \) \
      \SELECT count(*)::bigint, \
      \       COALESCE(bool_and(COALESCE((caps->>'reply')::boolean, false)), false), \
      \       COALESCE(bool_and(COALESCE((caps->>'reaction')::boolean, false)), false), \
      \       COALESCE(bool_and(COALESCE((caps->>'send_media')::boolean, false)), false), \
      \       COALESCE(bool_and(platform = 'qq'), false) \
      \FROM enabled"
      (Only legacyConversation)
  pure $ case rows :: [(Int64, Bool, Bool, Bool, Bool)] of
    [(count, reply, reaction, media, qqOnly)]
      | count > 0 ->
          ConversationOutputCapabilities
            { canOutputReply = reply,
              canOutputReaction = reaction,
              canOutputMedia = media,
              canOutputQQMention = qqOnly,
              canOutputQQFace = qqOnly
            }
    _ -> noConversationOutputCapabilities

data IngestOptions = IngestOptions
  { maxRawPayloadBytes :: !Int,
    createDispatch :: !Bool,
    createMirrorDeliveries :: !Bool,
    transcriptKind :: !Text,
    renderedTextOverride :: !(Maybe Text),
    compatibilitySegments :: !Value,
    compatibilityRawMessage :: !Text
  }
  deriving stock (Eq, Show, Generic)

defaultIngestOptions :: IngestOptions
defaultIngestOptions =
  IngestOptions
    { maxRawPayloadBytes = 65536,
      createDispatch = True,
      createMirrorDeliveries = True,
      transcriptKind = "chat",
      renderedTextOverride = Nothing,
      compatibilitySegments = toJSON ([] :: [Value]),
      compatibilityRawMessage = ""
    }

data IngestResult
  = Ingested !NewIngest
  | AlreadyIngested !CanonicalMessageId
  | DeliveryEcho !CanonicalMessageId
  deriving stock (Eq, Show, Generic)

data NewIngest = NewIngest
  { canonicalMessageId :: !CanonicalMessageId,
    dispatchCreated :: !Bool,
    mirrorDeliveriesCreated :: !Int64
  }
  deriving stock (Eq, Show, Generic)

-- | One durable eligibility decision waiting to cross into the live runtime.
-- The compatibility projection is kept at this boundary while Handler still
-- consumes OneBot-shaped messages; adapters and storage remain platform
-- neutral.
data DispatchClaim = DispatchClaim
  { canonicalMessageId :: !CanonicalMessageId,
    compatibilityMessageId :: !Int64,
    compatibilityConversationId :: !Int64,
    compatibilityUserId :: !Int64,
    compatibilitySelfId :: !Int64,
    compatibilitySegments :: !Value,
    replyToCompatibilityMessageId :: !(Maybe Int64),
    compatibilityRawMessage :: !Text,
    sourcePlatform :: !Text,
    senderNickname :: !(Maybe Text),
    senderCard :: !(Maybe Text),
    attemptCount :: !Int
  }
  deriving stock (Eq, Show, Generic)

data DispatchCompletion
  = DispatchCompleted
  | DispatchIgnored
  | DispatchRetry !Text !UTCTime
  deriving stock (Eq, Show, Generic)

data OutboundDraft = OutboundDraft
  { legacyConversationId :: !Int64,
    transcriptKind :: !Text,
    sourceCompatibilityMessageId :: !(Maybe Int64),
    canonicalContent :: !Value,
    renderedText :: !Text,
    compatibilitySegments :: !Value,
    replyToCompatibilityMessageId :: !(Maybe Int64)
  }
  deriving stock (Eq, Show, Generic)

data EnqueuedOutbound = EnqueuedOutbound
  { canonicalMessageId :: !CanonicalMessageId,
    compatibilityMessageId :: !Int64,
    primaryDeliveryId :: !DeliveryId,
    deliveriesCreated :: !Int64
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
    renderedText :: !Text,
    compatibilityConversationId :: !Int64,
    compatibilitySegments :: !Value,
    replyNativeEventId :: !(Maybe NativeEventId),
    originPlatform :: !Platform,
    senderDisplayName :: !(Maybe Text),
    messageOrigin :: !Text,
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

-- | A non-idempotent send accepted by the edge but not yet proven by an echo
-- or provider status.  These rows are intentionally absent from the delivery
-- claim queue: only reconciliation may move them again.
data UnconfirmedDelivery = UnconfirmedDelivery
  { deliveryId :: !DeliveryId,
    nativeEventId :: !NativeEventId,
    updatedAt :: !UTCTime
  }
  deriving stock (Eq, Show, Generic)

data PlatformEndpointStatus = PlatformEndpointStatus
  { endpointId :: !EndpointId,
    conversationId :: !ConversationId,
    legacyConversationId :: !(Maybe Int64),
    platform :: !Text,
    nativeAccountId :: !Text,
    nativeConversationId :: !Text,
    endpointMode :: !Text,
    enabled :: !Bool,
    capabilities :: !Value,
    cursors :: !Value,
    lastInboundAt :: !(Maybe UTCTime),
    pendingDeliveries :: !Int64,
    failedDeliveries :: !Int64,
    acceptedUnconfirmedDeliveries :: !Int64,
    outcomeUnknownDeliveries :: !Int64,
    suppressedDeliveries :: !Int64,
    oldestPendingAt :: !(Maybe UTCTime),
    lastDeliveryAt :: !(Maybe UTCTime)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

instance FromRow PlatformEndpointStatus where
  fromRow =
    PlatformEndpointStatus
      <$> (EndpointId <$> field)
      <*> (ConversationId <$> field)
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
    dcRenderedText :: !Text,
    dcCompatibilityConversationId :: !Int64,
    dcCompatibilitySegments :: !Value,
    dcReplyNativeEventId :: !(Maybe Text),
    dcOriginPlatform :: !Text,
    dcSenderDisplayName :: !(Maybe Text),
    dcMessageOrigin :: !Text,
    dcIdempotencyKey :: !Text,
    dcAttemptCount :: !Int,
    dcCapabilities :: !Value
  }

instance FromRow DeliveryClaimRow where
  fromRow =
    DeliveryClaimRow <$> field <*> field <*> field <*> field <*> field <*> field <*> field <*> field <*> field <*> field <*> field <*> field <*> field <*> field <*> field <*> field <*> field

data DispatchClaimRow = DispatchClaimRow
  { dcrCanonicalMessageId :: !Int64,
    dcrMessageId :: !Int64,
    dcrGroupId :: !Int64,
    dcrUserId :: !Int64,
    dcrSelfId :: !Int64,
    dcrSegments :: !Value,
    dcrReplyToMessageId :: !(Maybe Int64),
    dcrRawMessage :: !Text,
    dcrSourcePlatform :: !Text,
    dcrSenderNickname :: !(Maybe Text),
    dcrSenderCard :: !(Maybe Text),
    dcrAttemptCount :: !Int
  }

instance FromRow DispatchClaimRow where
  fromRow =
    DispatchClaimRow <$> field <*> field <*> field <*> field <*> field <*> field <*> field <*> field <*> field <*> field <*> field <*> field

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

-- | Resolve the endpoint used by legacy OneBot-shaped operations.  QQ is the
-- preferred operational endpoint of a mirror conversation; a standalone
-- foreign conversation resolves to its sole endpoint.
platformForLegacyConversation ::
  (WithConnection :> es, IOE :> es) =>
  Int64 ->
  Eff es (Maybe Text)
platformForLegacyConversation legacyId = do
  rows <-
    query
      "SELECT a.platform FROM conversations c \
      \JOIN conversation_endpoints e USING (conversation_id) \
      \JOIN platform_accounts a USING (platform_account_id) \
      \WHERE c.legacy_group_id = ? AND e.enabled AND a.enabled \
      \ORDER BY CASE a.platform WHEN 'qq' THEN 0 ELSE 1 END, e.endpoint_id \
      \LIMIT 1"
      (Only legacyId)
  pure (fromOnly <$> listToMaybe rows)

platformForLegacyMessage ::
  (WithConnection :> es, IOE :> es) =>
  Int64 ->
  Eff es (Maybe Text)
platformForLegacyMessage legacyMessageId = do
  rows <-
    query
      "SELECT a.platform FROM messages m \
      \JOIN conversation_endpoints e ON e.endpoint_id = m.origin_endpoint_id \
      \JOIN platform_accounts a USING (platform_account_id) \
      \WHERE m.message_id = ? AND e.enabled AND a.enabled"
      (Only legacyMessageId)
  pure (fromOnly <$> listToMaybe rows)

-- | Compatibility projection for the still-OneBot-shaped Handler boundary.
-- It is never routing or authorization authority.
compatibilityPlatformId ::
  (WithConnection :> es, IOE :> es) =>
  Platform ->
  Text ->
  Text ->
  Eff es Int64
compatibilityPlatformId platform kind = compatibilityId (renderPlatform platform) kind

isBotAuthoredCompatibilityMessage ::
  (WithConnection :> es, IOE :> es) =>
  Int64 ->
  Int64 ->
  Eff es Bool
isBotAuthoredCompatibilityMessage legacyConversation legacyMessage = do
  rows <-
    query
      "SELECT EXISTS ( \
      \ SELECT 1 FROM messages m \
      \ JOIN conversations c USING (conversation_id) \
      \ WHERE c.legacy_group_id = ? AND m.message_id = ? \
      \   AND m.message_origin IN ('outbound', 'internal'))"
      (legacyConversation, legacyMessage)
  pure $ case rows :: [Only Bool] of
    [Only authored] -> authored
    _ -> False

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
        conversationId = registration.conversationId,
        compatibilityConversationId = legacyGroup
      }

-- | Resolve or create the canonical endpoint corresponding to a legacy
-- bigint conversation.  Only edge adapters call this compatibility bridge;
-- the returned endpoint is the authority used by ingest and delivery.
ensureLegacyEndpoint ::
  (WithConnection :> es, IOE :> es) =>
  Platform ->
  NativeAccountId ->
  NativeConversationId ->
  ConversationKind ->
  Int64 ->
  PlatformCapabilities ->
  Eff es RegisteredEndpoint
ensureLegacyEndpoint platform nativeAccount nativeConversation kind legacyGroup capabilities =
  withTransaction $ do
    conversationRows <-
      query
        "INSERT INTO conversations (conversation_kind, legacy_group_id) \
        \ VALUES (?, ?) \
        \ ON CONFLICT (legacy_group_id) DO UPDATE \
        \ SET conversation_kind = EXCLUDED.conversation_kind \
        \ RETURNING conversation_id"
        (renderConversationKind kind, legacyGroup)
    let conversation = ConversationId (exactlyOne "ensureLegacyEndpoint conversation" conversationRows)
        platformName = renderPlatform platform
        NativeAccountId accountNative = nativeAccount
        NativeConversationId conversationNative = nativeConversation
        capabilitiesJson = Jsonb (capabilitiesValue capabilities)
    accountRows <-
      query
        "INSERT INTO platform_accounts (platform, native_account_id, capabilities) \
        \ VALUES (?, ?, ?) \
        \ ON CONFLICT (platform, native_account_id) DO UPDATE \
        \ SET capabilities = EXCLUDED.capabilities, updated_at = now() \
        \ RETURNING platform_account_id"
        (platformName, accountNative, capabilitiesJson)
    let account = exactlyOne "ensureLegacyEndpoint account" accountRows
    endpointRows <-
      query
        "INSERT INTO conversation_endpoints \
        \ (conversation_id, platform_account_id, native_conversation_id, endpoint_kind, capabilities) \
        \ VALUES (?, ?, ?, ?, ?) \
        \ ON CONFLICT (platform_account_id, native_conversation_id) DO UPDATE \
        \ SET conversation_id = EXCLUDED.conversation_id, endpoint_kind = EXCLUDED.endpoint_kind, \
        \     capabilities = EXCLUDED.capabilities, updated_at = now() \
        \ RETURNING endpoint_id"
        (conversation.unConversationId, account, conversationNative, renderConversationKind kind, capabilitiesJson)
    let endpoint = exactlyOne "ensureLegacyEndpoint endpoint" endpointRows
    -- A configured Matrix mirror may have claimed this legacy conversation
    -- before its QQ endpoint was first observed.  In that ordering the QQ
    -- endpoint must inherit mirror mode; otherwise both endpoints share the
    -- conversation but the relay query deliberately creates no deliveries.
    _ <-
      execute
        "UPDATE conversation_endpoints current_endpoint \
        \ SET endpoint_mode = 'mirror', updated_at = now() \
        \ WHERE current_endpoint.endpoint_id = ? \
        \   AND EXISTS ( \
        \     SELECT 1 FROM conversation_endpoints peer \
        \     JOIN platform_accounts peer_account USING (platform_account_id) \
        \     WHERE peer.conversation_id = current_endpoint.conversation_id \
        \       AND peer.endpoint_id <> current_endpoint.endpoint_id \
        \       AND peer.endpoint_mode = 'mirror' \
        \       AND peer_account.platform = 'matrix')"
        (Only endpoint)
    pure
      RegisteredEndpoint
        { endpointId = EndpointId endpoint,
          platformAccountId = PlatformAccountId account,
          conversationId = conversation,
          compatibilityConversationId = legacyGroup
        }

-- | Idempotently install one configured endpoint.  A mirror binds to the
-- explicitly named legacy conversation; a standalone endpoint reuses its own
-- prior conversation across restarts and creates one only on first boot.
ensureConfiguredEndpoint ::
  (WithConnection :> es, IOE :> es) =>
  Platform ->
  NativeAccountId ->
  NativeConversationId ->
  ConversationKind ->
  EndpointMode ->
  Maybe Int64 ->
  PlatformCapabilities ->
  Eff es RegisteredEndpoint
ensureConfiguredEndpoint platform nativeAccount nativeConversation kind mode mLegacy capabilities =
  withTransaction $ do
    let platformName = renderPlatform platform
        NativeAccountId accountNative = nativeAccount
        NativeConversationId conversationNative = nativeConversation
        capabilitiesJson = Jsonb (capabilitiesValue capabilities)
    accountRows <-
      query
        "INSERT INTO platform_accounts (platform, native_account_id, capabilities) \
        \ VALUES (?, ?, ?) \
        \ ON CONFLICT (platform, native_account_id) DO UPDATE \
        \ SET capabilities = EXCLUDED.capabilities, updated_at = now() \
        \ RETURNING platform_account_id"
        (platformName, accountNative, capabilitiesJson)
    let account = exactlyOne "ensureConfiguredEndpoint account" accountRows
    existing <-
      query
        "SELECT endpoint_id, conversation_id FROM conversation_endpoints \
        \ WHERE platform_account_id = ? AND native_conversation_id = ? FOR UPDATE"
        (account, conversationNative)
    (endpoint, conversation) <- case existing :: [(Int64, Int64)] of
      [(endpointId', conversationId')] -> pure (endpointId', conversationId')
      [] -> do
        conversationRows <- case mLegacy of
          Just legacy ->
            query
              "INSERT INTO conversations (conversation_kind, legacy_group_id) VALUES (?, ?) \
              \ ON CONFLICT (legacy_group_id) DO UPDATE \
              \ SET conversation_kind = EXCLUDED.conversation_kind \
              \ RETURNING conversation_id"
              (renderConversationKind kind, legacy)
          Nothing ->
            query
              "INSERT INTO conversations (conversation_kind) VALUES (?) RETURNING conversation_id"
              (Only (renderConversationKind kind))
        let conversationId' = exactlyOne "ensureConfiguredEndpoint conversation" conversationRows
        -- Standalone conversations still need an opaque compatibility key for
        -- unchanged context/session readers.  It is not routing authority.
        case mLegacy of
          Just _ -> pure ()
          Nothing -> do
            projected <- compatibilityId platformName "channel" conversationNative
            _ <-
              execute
                "UPDATE conversations SET legacy_group_id = ? WHERE conversation_id = ?"
                (projected, conversationId')
            pure ()
        endpointRows <-
          query
            "INSERT INTO conversation_endpoints \
            \ (conversation_id, platform_account_id, native_conversation_id, endpoint_kind, endpoint_mode, capabilities) \
            \ VALUES (?, ?, ?, ?, ?, ?) RETURNING endpoint_id"
            ( conversationId',
              account,
              conversationNative,
              renderConversationKind kind,
              renderEndpointMode mode,
              capabilitiesJson
            )
        pure (exactlyOne "ensureConfiguredEndpoint endpoint" endpointRows, conversationId')
      _ -> error "ensureConfiguredEndpoint: duplicate endpoint invariant violated"
    _ <-
      execute
        "UPDATE conversation_endpoints \
        \ SET endpoint_mode = ?, endpoint_kind = ?, capabilities = ?, enabled = true, updated_at = now() \
        \ WHERE endpoint_id = ?"
        (renderEndpointMode mode, renderConversationKind kind, capabilitiesJson, endpoint)
    -- Attaching a configured Matrix mirror to an already active QQ
    -- conversation is one linking operation.  Promote the existing QQ side
    -- in the same transaction so there is never a half-mirror that silently
    -- drops relay deliveries.
    case (mode, mLegacy) of
      (EndpointMirror, Just _) -> do
        _ <-
          execute
            "UPDATE conversation_endpoints peer \
            \ SET endpoint_mode = 'mirror', updated_at = now() \
            \ FROM platform_accounts peer_account \
            \ WHERE peer.platform_account_id = peer_account.platform_account_id \
            \   AND peer.conversation_id = ? \
            \   AND peer_account.platform = 'qq'"
            (Only conversation)
        pure ()
      _ -> pure ()
    legacyRows <-
      query
        "SELECT legacy_group_id FROM conversations WHERE conversation_id = ?"
        (Only conversation)
    legacyConversation <- case legacyRows :: [Only (Maybe Int64)] of
      [Only (Just legacy)] -> pure legacy
      _ -> error "ensureConfiguredEndpoint: conversation lacks compatibility projection"
    pure
      RegisteredEndpoint
        { endpointId = EndpointId endpoint,
          platformAccountId = PlatformAccountId account,
          conversationId = ConversationId conversation,
          compatibilityConversationId = legacyConversation
        }

latestNativeEventId ::
  (WithConnection :> es, IOE :> es) =>
  EndpointId ->
  Eff es (Maybe NativeEventId)
latestNativeEventId (EndpointId endpoint) = do
  rows <-
    query
      "SELECT native_event_id FROM platform_events \
      \ WHERE endpoint_id = ? AND canonical_message_id IS NOT NULL \
      \ ORDER BY platform_event_id DESC LIMIT 1"
      (Only endpoint)
  pure (NativeEventId . fromOnly <$> listToMaybe rows)

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
  identityId <- ensurePrincipalIdentity endpoint envelope.senderNativeId envelope.senderDisplayName
  let NativeEventId nativeEvent = envelope.nativeEventId
      (safeRaw, rawTruncated) = sanitizeRawPayload options.maxRawPayloadBytes envelope.rawPayload
      ingestLockKey = T.pack (show envelope.endpointId.unEndpointId) <> ":" <> nativeEvent
  -- The platform-event row is initially a reservation and receives its
  -- canonical_message_id later in this transaction. Serialize only identical
  -- native events so a duplicate delivery cannot observe or try to repair
  -- that deliberately intermediate state. Different events remain fully
  -- concurrent, including events on the same endpoint.
  lockRows <-
    query
      "SELECT pg_advisory_xact_lock(hashtextextended(?::text, 0)) IS NULL"
      (Only ingestLockKey)
  case lockRows :: [Only Bool] of
    [_] -> pure ()
    _ -> error "ingestEnvelope: advisory lock did not return one row"
  reconciled <- reconcileDeliveryEcho endpoint identityId safeRaw rawTruncated
  case reconciled of
    Just cid -> pure (DeliveryEcho (CanonicalMessageId cid))
    Nothing -> do
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
            -- A pre-hardening writer may have committed an incomplete
            -- reservation. The per-native-event transaction lock makes this
            -- caller its sole repair owner.
            [Only Nothing] -> insertCanonical endpoint identityId safeRaw
            _ -> error "ingestEnvelope: event reservation disappeared"
        [_] -> insertCanonical endpoint identityId safeRaw
        _ -> error "ingestEnvelope: event reservation returned multiple rows"
  where
    options = sanitizeIngestOptions unsafeOptions
    envelope = sanitizeInboundEnvelope unsafeEnvelope

    reconcileDeliveryEcho endpoint identityId safeRaw rawTruncated = do
      let NativeEventId nativeEvent = envelope.nativeEventId
          NativeUserId sender = envelope.senderNativeId
          contentValue = canonicalContentValue envelope.content
      exact <-
        query
          "SELECT canonical_message_id FROM message_deliveries \
          \ WHERE endpoint_id = ? AND native_event_id = ? \
          \   AND idempotency_key NOT LIKE 'source:%' \
          \ FOR UPDATE"
          (envelope.endpointId.unEndpointId, nativeEvent)
      candidate <- case exact :: [Only Int64] of
        [Only cid] -> pure (Just cid)
        []
          | sender == endpoint.erNativeAccountId -> do
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
        _ <-
          execute
            "UPDATE message_deliveries \
            \ SET status = 'confirmed', native_event_id = ?, confirmed_at = ?, \
            \     lease_owner = NULL, lease_expires_at = NULL, last_error = NULL, updated_at = now() \
            \ WHERE canonical_message_id = ? AND endpoint_id = ?"
            (nativeEvent, envelope.receivedAt, cid, envelope.endpointId.unEndpointId)
        _ <-
          execute
            "INSERT INTO platform_events \
            \ (endpoint_id, native_event_id, sender_identity_id, event_kind, occurred_at, received_at, \
            \  source_cursor, raw_payload, raw_payload_truncated, canonical_message_id) \
            \ VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?) \
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
              cid
            )
        pure cid

    insertCanonical endpoint identityId _safeRaw = do
      let platformName = endpoint.erPlatform
          NativeEventId nativeEvent = envelope.nativeEventId
          NativeUserId nativeUser = envelope.senderNativeId
          contentValue = canonicalContentValue envelope.content
          rendered = fromMaybe (renderCanonicalText envelope.content) options.renderedTextOverride
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
          \  author_principal_id, origin_endpoint_id, source_native_event_id, message_origin, source_platform) \
          \ SELECT ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, \
          \        pi.principal_id, ?, ?, 'inbound', ? \
          \ FROM principal_identities pi WHERE pi.principal_identity_id = ? \
          \ RETURNING canonical_message_id"
          ( legacyMessage,
            legacyGroup,
            legacyUser,
            legacySelf,
            envelope.receivedAt,
            envelope.occurredAt,
            Jsonb options.compatibilitySegments,
            Jsonb contentValue,
            rendered,
            options.compatibilityRawMessage,
            envelope.senderDisplayName,
            replyLegacy,
            replyCanonical,
            options.transcriptKind,
            endpoint.erConversationId,
            envelope.endpointId.unEndpointId,
            nativeEvent,
            platformName,
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
      dispatchCount <- case envelope.eventKind of
        EventMessage | options.createDispatch ->
          execute
            "UPDATE message_dispatches SET status = 'pending', updated_at = now() \
            \ WHERE canonical_message_id = ?"
            (Only cid)
        _ -> pure 0
      mirrorCount <- case envelope.eventKind of
        EventMessage | options.createMirrorDeliveries ->
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
        _ -> pure 0
      forM_ envelope.relations (insertRelation cid envelope.endpointId)
      pure
        ( Ingested
            NewIngest
            { canonicalMessageId = CanonicalMessageId cid,
              dispatchCreated = dispatchCount == 1,
              mirrorDeliveriesCreated = mirrorCount
            }
        )

-- | Publish one bot-authored semantic message and every endpoint copy in one
-- transaction.  No network operation precedes this commit, so a crash can
-- delay delivery but cannot create an externally visible message with no
-- canonical ledger row.
enqueueOutbound ::
  (WithConnection :> es, IOE :> es) =>
  OutboundDraft ->
  Eff es EnqueuedOutbound
enqueueOutbound draft = withTransaction $ do
  primaryRows <-
    query
      "SELECT e.endpoint_id, e.conversation_id, e.platform_account_id, a.platform, \
      \       a.native_account_id, c.legacy_group_id \
      \ FROM conversations c \
      \ JOIN conversation_endpoints e USING (conversation_id) \
      \ JOIN platform_accounts a USING (platform_account_id) \
      \ WHERE c.legacy_group_id = ? AND e.enabled AND a.enabled \
      \   AND (?::bigint IS NULL OR e.endpoint_id = ( \
      \     SELECT source.origin_endpoint_id FROM messages source \
      \     WHERE source.group_id = ? AND source.message_id = ?)) \
      \ ORDER BY CASE a.platform WHEN 'qq' THEN 0 ELSE 1 END, e.endpoint_id \
      \ LIMIT 1 FOR UPDATE OF c"
      ( draft.legacyConversationId,
        draft.sourceCompatibilityMessageId,
        draft.legacyConversationId,
        draft.sourceCompatibilityMessageId
      )
  (primaryEndpoint, conversation, account, platformName, accountNative, legacyGroup) <-
    case primaryRows :: [(Int64, Int64, Int64, Text, Text, Maybe Int64)] of
      [row] -> pure row
      _ -> error "enqueueOutbound: conversation has no enabled endpoint"
  identityId <-
    ensurePrincipalIdentity
      EndpointRow
        { erConversationId = conversation,
          erPlatformAccountId = account,
          erPlatform = platformName,
          erNativeAccountId = accountNative,
          erLegacyGroupId = legacyGroup
        }
      (NativeUserId accountNative)
      (Just "max")
  principalRows <-
    query
      "SELECT principal_id FROM principal_identities WHERE principal_identity_id = ?"
      (Only identityId)
  let principal = exactlyOne "enqueueOutbound principal" (principalRows :: [Only Int64])
  canonicalRows <- query "SELECT nextval('canonical_message_id_seq')" ()
  let canonical = exactlyOne "enqueueOutbound canonical id" (canonicalRows :: [Only Int64])
  compatibilityRows <- query "SELECT -nextval('synthetic_message_id_seq')" ()
  let compatibilityMessage = exactlyOne "enqueueOutbound compatibility id" (compatibilityRows :: [Only Int64])
  compatibilitySelf <- compatibilityId platformName "user" accountNative
  replyCanonical <- case draft.replyToCompatibilityMessageId of
    Nothing -> pure Nothing
    Just replyLegacy -> do
      rows <-
        query
          "SELECT canonical_message_id FROM messages \
          \ WHERE conversation_id = ? AND message_id = ?"
          (conversation, replyLegacy)
      pure (fromOnly <$> listToMaybe (rows :: [Only Int64]))
  inserted <-
    execute
      "INSERT INTO messages \
      \ (canonical_message_id, message_id, group_id, user_id, self_id, segments, canonical_content, \
      \  rendered_text, raw_message, sender_nickname, reply_to_message_id, reply_to_canonical_message_id, \
      \  kind, conversation_id, author_principal_id, origin_endpoint_id, source_native_event_id, \
      \  occurred_at, message_origin, source_platform) \
      \ VALUES (?, ?, ?, ?, ?, ?, ?, ?, '', 'max', ?, ?, ?, ?, ?, ?, ?, now(), 'outbound', ?)"
      ( canonical,
        compatibilityMessage,
        draft.legacyConversationId,
        compatibilitySelf,
        compatibilitySelf,
        Jsonb draft.compatibilitySegments,
        Jsonb draft.canonicalContent,
        draft.renderedText,
        draft.replyToCompatibilityMessageId,
        replyCanonical,
        draft.transcriptKind,
        conversation,
        principal,
        primaryEndpoint,
        "max:" <> T.pack (show canonical),
        platformName
      )
  if inserted /= 1 then error "enqueueOutbound: canonical insert did not affect one row" else pure ()
  -- Delivery adapters resolve replies through the canonical relation table,
  -- not through the legacy compatibility column.  Keeping both projections
  -- in the same publish transaction lets Matrix preserve native replies and
  -- lets capability-limited endpoints deliberately degrade them without ever
  -- exposing the model's @[↩#...]@ token.
  forM_ replyCanonical $ \target -> do
    _ <-
      execute
        "INSERT INTO message_relations \
        \ (canonical_message_id, relation_kind, target_canonical_message_id) \
        \ VALUES (?, 'reply', ?) ON CONFLICT DO NOTHING"
        (canonical, target)
    pure ()
  _ <-
    execute
      "INSERT INTO message_dispatches (canonical_message_id, status, completed_at) \
      \ VALUES (?, 'ignored', now())"
      (Only canonical)
  deliveryCount <-
    execute
      "INSERT INTO message_deliveries \
      \ (canonical_message_id, endpoint_id, status, idempotency_key) \
      \ SELECT ?, e.endpoint_id, 'pending', 'out:' || ?::text || ':' || e.endpoint_id::text \
      \ FROM conversation_endpoints e \
      \ JOIN platform_accounts a USING (platform_account_id) \
      \ WHERE e.conversation_id = ? AND e.enabled AND a.enabled \
      \   AND (?::boolean OR e.endpoint_id = ?) \
      \ ON CONFLICT (canonical_message_id, endpoint_id) DO NOTHING"
      (canonical, canonical, conversation, draft.sourceCompatibilityMessageId == Nothing, primaryEndpoint)
  primaryDeliveryRows <-
    query
      "SELECT delivery_id FROM message_deliveries \
      \ WHERE canonical_message_id = ? AND endpoint_id = ?"
      (canonical, primaryEndpoint)
  pure
    EnqueuedOutbound
      { canonicalMessageId = CanonicalMessageId canonical,
        compatibilityMessageId = compatibilityMessage,
        primaryDeliveryId = DeliveryId (exactlyOne "enqueueOutbound primary delivery" primaryDeliveryRows),
        deliveriesCreated = deliveryCount
      }

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

claimDispatches ::
  (WithConnection :> es, IOE :> es) =>
  Text ->
  Int ->
  NominalDiffTime ->
  Eff es [DispatchClaim]
claimDispatches workerId limit leaseDuration =
  claimDispatchWhere workerId Nothing limit leaseDuration

-- | Claim one known message immediately after ingest.  If another runtime won
-- the lease, or this event was already evaluated, return 'Nothing'.
claimDispatch ::
  (WithConnection :> es, IOE :> es) =>
  Text ->
  CanonicalMessageId ->
  NominalDiffTime ->
  Eff es (Maybe DispatchClaim)
claimDispatch workerId (CanonicalMessageId canonical) leaseDuration = do
  claims <-
    claimDispatchWhere workerId (Just canonical) 1 leaseDuration
  pure (listToMaybe claims)

claimDispatchWhere ::
  (WithConnection :> es, IOE :> es) =>
  Text ->
  Maybe Int64 ->
  Int ->
  NominalDiffTime ->
  Eff es [DispatchClaim]
claimDispatchWhere workerId mCanonical limit leaseDuration = do
  rows <-
    query
      "WITH candidates AS ( \
        \ SELECT md.canonical_message_id FROM message_dispatches md \
        \ WHERE md.status IN ('pending', 'failed') \
        \   AND md.next_attempt_at <= now() \
        \   AND (md.lease_expires_at IS NULL OR md.lease_expires_at < now()) \
        \   AND (?::bigint IS NULL OR md.canonical_message_id = ?) \
        \ ORDER BY md.next_attempt_at, md.canonical_message_id \
        \ FOR UPDATE OF md SKIP LOCKED LIMIT ? \
        \), claimed AS ( \
        \ UPDATE message_dispatches md \
        \ SET status = 'claimed', lease_owner = ?, \
        \     lease_expires_at = now() + (?::double precision * interval '1 second'), \
        \     attempt_count = attempt_count + 1, last_attempt_at = now(), updated_at = now() \
        \ FROM candidates c WHERE md.canonical_message_id = c.canonical_message_id \
        \ RETURNING md.canonical_message_id, md.attempt_count \
        \) \
        \SELECT c.canonical_message_id, m.message_id, m.group_id, m.user_id, m.self_id, \
        \       m.segments, m.reply_to_message_id, m.raw_message, m.source_platform, m.sender_nickname, m.sender_card, c.attempt_count \
        \FROM claimed c JOIN messages m USING (canonical_message_id) \
        \ORDER BY c.canonical_message_id"
      ( mCanonical,
        mCanonical,
        limit,
        workerId,
        realToFrac leaseDuration :: Double
      )
  pure (toDispatchClaim <$> (rows :: [DispatchClaimRow]))

completeDispatch ::
  (WithConnection :> es, IOE :> es) =>
  Text ->
  CanonicalMessageId ->
  DispatchCompletion ->
  Eff es Bool
completeDispatch workerId (CanonicalMessageId canonical) completion = do
  changed <- case completion of
    DispatchCompleted -> finish "completed" Nothing Nothing True
    DispatchIgnored -> finish "ignored" Nothing Nothing True
    DispatchRetry err next -> finish "failed" (Just err) (Just next) False
  pure (changed == 1)
  where
    finish status lastError next completed =
      execute
        "UPDATE message_dispatches \
        \ SET status = ?, last_error = ?, next_attempt_at = COALESCE(?, next_attempt_at), \
        \     completed_at = CASE WHEN ? THEN now() ELSE completed_at END, \
        \     lease_owner = NULL, lease_expires_at = NULL, updated_at = now() \
        \ WHERE canonical_message_id = ? AND status = 'claimed' AND lease_owner = ?"
        (status :: Text, lastError, next, completed, canonical, workerId)

claimDeliveries ::
  (WithConnection :> es, IOE :> es) =>
  Text -> -- ^ stable worker id
  Int ->
  NominalDiffTime ->
  Eff es [DeliveryClaim]
claimDeliveries workerId limit leaseDuration = do
  claimDeliveriesWhere workerId Nothing limit leaseDuration

claimDelivery ::
  (WithConnection :> es, IOE :> es) =>
  Text ->
  DeliveryId ->
  NominalDiffTime ->
  Eff es (Maybe DeliveryClaim)
claimDelivery workerId (DeliveryId delivery) leaseDuration = do
  claims <- claimDeliveriesWhere workerId (Just delivery) 1 leaseDuration
  pure (listToMaybe claims)

claimDeliveriesWhere ::
  (WithConnection :> es, IOE :> es) =>
  Text ->
  Maybe Int64 ->
  Int ->
  NominalDiffTime ->
  Eff es [DeliveryClaim]
claimDeliveriesWhere workerId mDelivery limit leaseDuration = do
  rows <-
    query
      "WITH candidates AS ( \
      \ SELECT d.delivery_id FROM message_deliveries d \
      \ JOIN conversation_endpoints e ON e.endpoint_id = d.endpoint_id AND e.enabled \
      \ JOIN platform_accounts a ON a.platform_account_id = e.platform_account_id AND a.enabled \
      \ WHERE d.status IN ('pending', 'failed') \
      \   AND d.next_attempt_at <= now() \
      \   AND (d.lease_expires_at IS NULL OR d.lease_expires_at < now()) \
      \   AND (?::bigint IS NULL OR d.delivery_id = ?) \
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
      \        m.rendered_text, m.group_id, m.segments, \
      \        (SELECT COALESCE(target_delivery.native_event_id, target_event.native_event_id) \
      \           FROM message_relations relation \
      \           LEFT JOIN message_deliveries target_delivery \
      \             ON target_delivery.canonical_message_id = relation.target_canonical_message_id \
      \            AND target_delivery.endpoint_id = c.endpoint_id \
      \           LEFT JOIN platform_events target_event \
      \             ON target_event.canonical_message_id = relation.target_canonical_message_id \
      \            AND target_event.endpoint_id = c.endpoint_id \
      \          WHERE relation.canonical_message_id = c.canonical_message_id \
      \            AND relation.relation_kind = 'reply' LIMIT 1), \
      \        origin_account.platform, COALESCE(m.sender_card, m.sender_nickname), m.message_origin, \
      \        c.idempotency_key, c.attempt_count, \
      \        CASE WHEN e.capabilities = '{}'::jsonb THEN a.capabilities ELSE e.capabilities END \
      \ FROM claimed c \
      \ JOIN conversation_endpoints e ON e.endpoint_id = c.endpoint_id \
      \ JOIN platform_accounts a ON a.platform_account_id = e.platform_account_id \
      \ JOIN messages m ON m.canonical_message_id = c.canonical_message_id \
      \ JOIN conversation_endpoints origin_endpoint ON origin_endpoint.endpoint_id = m.origin_endpoint_id \
      \ JOIN platform_accounts origin_account ON origin_account.platform_account_id = origin_endpoint.platform_account_id \
      \ ORDER BY c.delivery_id"
      (mDelivery, mDelivery, limit, workerId, realToFrac leaseDuration :: Double)
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

listUnconfirmedDeliveries ::
  (WithConnection :> es, IOE :> es) =>
  Platform ->
  Int ->
  Eff es [UnconfirmedDelivery]
listUnconfirmedDeliveries platform limit = do
  rows <-
    query
      "SELECT d.delivery_id, d.native_event_id, d.updated_at \
      \ FROM message_deliveries d \
      \ JOIN conversation_endpoints e USING (endpoint_id) \
      \ JOIN platform_accounts a USING (platform_account_id) \
      \ WHERE a.platform = ? AND d.status = 'accepted_unconfirmed' \
      \   AND d.native_event_id IS NOT NULL \
      \ ORDER BY d.updated_at, d.delivery_id LIMIT ?"
      (renderPlatform platform, limit)
  pure
    [ UnconfirmedDelivery (DeliveryId delivery) (NativeEventId native) updated
    | (delivery, native, updated) <- rows
    ]

-- | Reconciliation CAS independent of a delivery lease.  A late status query
-- cannot overwrite an echo that already confirmed the same row.
confirmUnconfirmedDelivery ::
  (WithConnection :> es, IOE :> es) =>
  DeliveryId ->
  NativeEventId ->
  Eff es Bool
confirmUnconfirmedDelivery (DeliveryId delivery) (NativeEventId native) = do
  changed <-
    execute
      "UPDATE message_deliveries \
      \ SET status = 'confirmed', confirmed_at = now(), last_error = NULL, updated_at = now() \
      \ WHERE delivery_id = ? AND native_event_id = ? AND status = 'accepted_unconfirmed'"
      (delivery, native)
  pure (changed == 1)

-- | A provider's explicit @failed@ send status proves the earlier accepted
-- attempt did not complete.  Only that evidence may put a non-idempotent send
-- back on the ordinary retry queue.
retryUnconfirmedDelivery ::
  (WithConnection :> es, IOE :> es) =>
  DeliveryId ->
  NativeEventId ->
  Text ->
  Eff es Bool
retryUnconfirmedDelivery (DeliveryId delivery) (NativeEventId native) reason = do
  changed <-
    execute
      "UPDATE message_deliveries \
      \ SET status = 'failed', next_attempt_at = now(), last_error = ?, updated_at = now() \
      \ WHERE delivery_id = ? AND native_event_id = ? AND status = 'accepted_unconfirmed'"
      (reason, delivery, native)
  pure (changed == 1)

listPlatformStatus ::
  (WithConnection :> es, IOE :> es) =>
  Eff es [PlatformEndpointStatus]
listPlatformStatus =
  query
    "SELECT e.endpoint_id, e.conversation_id, c.legacy_group_id, a.platform, \
    \       a.native_account_id, e.native_conversation_id, e.endpoint_mode, \
    \       (e.enabled AND a.enabled), \
    \       CASE WHEN e.capabilities = '{}'::jsonb THEN a.capabilities ELSE e.capabilities END, \
    \       COALESCE(( \
    \         SELECT jsonb_agg(jsonb_build_object( \
    \           'stream_key', pc.stream_key, 'cursor', pc.cursor, \
    \           'source_fingerprint', pc.source_fingerprint, \
    \           'revision', pc.revision, 'updated_at', pc.updated_at) \
    \           ORDER BY pc.stream_key) \
    \         FROM platform_ingest_cursors pc \
    \         WHERE pc.platform_account_id = a.platform_account_id \
    \       ), '[]'::jsonb), \
    \       (SELECT max(pe.received_at) FROM platform_events pe WHERE pe.endpoint_id = e.endpoint_id), \
    \       (SELECT count(*) FROM message_deliveries d WHERE d.endpoint_id = e.endpoint_id AND d.status IN ('pending', 'sending')), \
    \       (SELECT count(*) FROM message_deliveries d WHERE d.endpoint_id = e.endpoint_id AND d.status = 'failed'), \
    \       (SELECT count(*) FROM message_deliveries d WHERE d.endpoint_id = e.endpoint_id AND d.status = 'accepted_unconfirmed'), \
    \       (SELECT count(*) FROM message_deliveries d WHERE d.endpoint_id = e.endpoint_id AND d.status = 'outcome_unknown'), \
    \       (SELECT count(*) FROM message_deliveries d WHERE d.endpoint_id = e.endpoint_id AND d.status = 'suppressed'), \
    \       (SELECT min(d.created_at) FROM message_deliveries d WHERE d.endpoint_id = e.endpoint_id AND d.status IN ('pending', 'sending', 'failed')), \
    \       (SELECT max(d.updated_at) FROM message_deliveries d WHERE d.endpoint_id = e.endpoint_id) \
    \ FROM conversation_endpoints e \
    \ JOIN platform_accounts a USING (platform_account_id) \
    \ JOIN conversations c USING (conversation_id) \
    \ ORDER BY e.conversation_id, e.endpoint_id"
    ()

sanitizeRawPayload :: Int -> Maybe Value -> (Maybe Value, Bool)
sanitizeRawPayload _ Nothing = (Nothing, False)
sanitizeRawPayload maxBytes (Just raw) =
  let sanitized = redact (sanitizePostgresValue raw)
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

-- PostgreSQL text and jsonb reject U+0000 even though upstream JSON decoders
-- can represent it.  Normalize that single forbidden code point at the shared
-- ingest boundary so one malformed platform event cannot wedge a durable
-- cursor.  U+FFFD keeps the lossy position explicit instead of silently
-- deleting content.
sanitizePostgresText :: Text -> Text
sanitizePostgresText = T.map (\c -> if c == '\NUL' then '\xfffd' else c)

sanitizePostgresValue :: Value -> Value
sanitizePostgresValue = \case
  Object values ->
    Object . KeyMap.fromList $
      [ ( Key.fromText (sanitizePostgresText (Key.toText key)),
          sanitizePostgresValue value
        )
      | (key, value) <- KeyMap.toList values
      ]
  Array values -> Array (fmap sanitizePostgresValue values)
  String body -> String (sanitizePostgresText body)
  other -> other

sanitizeInboundEnvelope :: InboundEnvelope -> InboundEnvelope
sanitizeInboundEnvelope envelope =
  envelope
    { nativeEventId = sanitizeNativeEventId envelope.nativeEventId,
      senderNativeId = sanitizeNativeUserId envelope.senderNativeId,
      senderDisplayName = sanitizePostgresText <$> envelope.senderDisplayName,
      content = sanitizeContentPart <$> envelope.content,
      relations = sanitizeRelation <$> envelope.relations,
      sourceCursor = sanitizeCursor <$> envelope.sourceCursor,
      rawPayload = sanitizePostgresValue <$> envelope.rawPayload
    }
  where
    sanitizeCursor (PlatformCursor value) = PlatformCursor (sanitizePostgresValue value)

sanitizeIngestOptions :: IngestOptions -> IngestOptions
sanitizeIngestOptions options =
  options
    { transcriptKind = sanitizePostgresText options.transcriptKind,
      renderedTextOverride = sanitizePostgresText <$> options.renderedTextOverride,
      compatibilitySegments = sanitizePostgresValue options.compatibilitySegments,
      compatibilityRawMessage = sanitizePostgresText options.compatibilityRawMessage
    }

sanitizeNativeUserId :: NativeUserId -> NativeUserId
sanitizeNativeUserId (NativeUserId native) = NativeUserId (sanitizePostgresText native)

sanitizeNativeEventId :: NativeEventId -> NativeEventId
sanitizeNativeEventId (NativeEventId native) = NativeEventId (sanitizePostgresText native)

sanitizeRelation :: MessageRelation -> MessageRelation
sanitizeRelation = \case
  ReplyTo native -> ReplyTo (sanitizeNativeEventId native)
  Replaces native -> Replaces (sanitizeNativeEventId native)
  ReactsTo native reaction ->
    ReactsTo (sanitizeNativeEventId native) (sanitizePostgresText reaction)

sanitizeContentPart :: ContentPart -> ContentPart
sanitizeContentPart = \case
  ContentText body -> ContentText (sanitizePostgresText body)
  ContentMention native display ->
    ContentMention (sanitizeNativeUserId native) (sanitizePostgresText <$> display)
  ContentMedia source display ->
    ContentMedia (sanitizeMediaSource source) (sanitizePostgresText <$> display)
  ContentUnsupported label -> ContentUnsupported (sanitizePostgresText label)

sanitizeMediaSource :: MediaSource -> MediaSource
sanitizeMediaSource = \case
  RemoteMedia uri mime bytes digest ->
    RemoteMedia
      (sanitizePostgresText uri)
      (sanitizePostgresText <$> mime)
      bytes
      (sanitizePostgresText <$> digest)
  InlineMedia bytes mime name ->
    InlineMedia bytes (sanitizePostgresText <$> mime) (sanitizePostgresText <$> name)

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
      renderedText = row.dcRenderedText,
      compatibilityConversationId = row.dcCompatibilityConversationId,
      compatibilitySegments = row.dcCompatibilitySegments,
      replyNativeEventId = NativeEventId <$> row.dcReplyNativeEventId,
      originPlatform = parsePlatform row.dcOriginPlatform,
      senderDisplayName = row.dcSenderDisplayName,
      messageOrigin = row.dcMessageOrigin,
      idempotencyKey = row.dcIdempotencyKey,
      attemptCount = row.dcAttemptCount,
      capabilities = row.dcCapabilities
    }

toDispatchClaim :: DispatchClaimRow -> DispatchClaim
toDispatchClaim row =
  DispatchClaim
    { canonicalMessageId = CanonicalMessageId row.dcrCanonicalMessageId,
      compatibilityMessageId = row.dcrMessageId,
      compatibilityConversationId = row.dcrGroupId,
      compatibilityUserId = row.dcrUserId,
      compatibilitySelfId = row.dcrSelfId,
      compatibilitySegments = row.dcrSegments,
      replyToCompatibilityMessageId = row.dcrReplyToMessageId,
      compatibilityRawMessage = row.dcrRawMessage,
      sourcePlatform = row.dcrSourcePlatform,
      senderNickname = row.dcrSenderNickname,
      senderCard = row.dcrSenderCard,
      attemptCount = row.dcrAttemptCount
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
