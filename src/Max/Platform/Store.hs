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
    compatibilityMessageIdForCanonical,
    conversationAdvertisedCaps,
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
    recordInternalMessage,
    ReactionDraft (..),
    EnqueuedReaction (..),
    enqueueReaction,
    CursorRecord (..),
    readIngestCursor,
    advanceIngestCursorCAS,
    DeliveryClaim (..),
    deliveryMentionNatives,
    expiredSendingDeliverySql,
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
  )
where

import Control.Applicative ((<|>))
import Control.Monad (forM, forM_, when)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.Aeson
  ( KeyValue ((.=)),
    Result (..),
    ToJSON,
    Value (..),
    encode,
    fromJSON,
    object,
    toJSON,
  )
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Base16 qualified as Base16
import Data.ByteString.Lazy qualified as LBS
import Data.Int (Int64)
import Data.List (find)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust, isNothing, listToMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (NominalDiffTime, UTCTime)
import Database.PostgreSQL.Simple (Query)
import Database.PostgreSQL.Simple.FromRow (FromRow (..), field)
import Database.PostgreSQL.Simple.ToField (ToField (..), toJSONField)
import Database.PostgreSQL.Simple.Types (Only (..), PGArray (..))
import Effectful
import Effectful.PostgreSQL (WithConnection, execute, query)
import GHC.Generics (Generic)
import Max.DB.Transaction (withTransaction)
import Max.IR
import Max.IR.Lower
  ( Attribution (..),
    LowerNote,
    OutboundCaps (..),
    ReplyContext (..),
    outboundCapsFromValue,
    outboundCapsToValue,
    platformDisplayLabel,
    Tier (..),
  )
import Max.IR.Prompt (promptCanonicalText)
import Max.Platform.Envelope (InboundEnvelope (..))
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
    capabilities :: !OutboundCaps
  }
  deriving stock (Eq, Show, Generic)

data RegisteredEndpoint = RegisteredEndpoint
  { endpointId :: !EndpointId,
    platformAccountId :: !PlatformAccountId,
    conversationId :: !ConversationId,
    compatibilityConversationId :: !Int64
  }
  deriving stock (Eq, Show, Generic)

-- | Derive the semantic surface advertised to the model.  Content actions
-- are enabled when they have a total lowering path; joining a text-only
-- endpoint therefore cannot hide reply, mention or media.  Reactions and QQ
-- faces remain gated because they have no textual action equivalent.
conversationAdvertisedCaps ::
  (WithConnection :> es, IOE :> es) =>
  Int64 ->
  Maybe Int64 ->
  Eff es AdvertisedCaps
conversationAdvertisedCaps legacyConversation targetCompatibilityMessage = do
  rows <-
    query
      "SELECT a.platform, CASE WHEN e.capabilities = '{}'::jsonb THEN a.capabilities ELSE e.capabilities END, \
      \       (?::bigint IS NULL OR EXISTS ( \
      \          SELECT 1 FROM messages target \
      \          WHERE target.conversation_id = c.conversation_id AND target.message_id = ? \
      \            AND ( \
      \              EXISTS (SELECT 1 FROM platform_events pe \
      \                      WHERE pe.endpoint_id = e.endpoint_id \
      \                        AND pe.canonical_message_id = target.canonical_message_id) \
      \              OR EXISTS (SELECT 1 FROM message_deliveries d \
      \                         WHERE d.endpoint_id = e.endpoint_id \
      \                           AND d.canonical_message_id = target.canonical_message_id \
      \                           AND d.native_event_id IS NOT NULL)))) \
      \FROM conversations c \
      \ JOIN conversation_endpoints e USING (conversation_id) \
      \ JOIN platform_accounts a USING (platform_account_id) \
      \ WHERE c.legacy_group_id = ? AND e.enabled AND a.enabled \
      \ ORDER BY e.endpoint_id"
      (targetCompatibilityMessage, targetCompatibilityMessage, legacyConversation)
  let endpoints =
        [ (parsePlatform platform, outboundCapsFromValue manifest, holdsTarget)
        | (platform, manifest, holdsTarget) <- (rows :: [(Text, Value, Bool)])
        ]
      present = not (null endpoints)
      anyMedia caps = any (/= TierDrop) [caps.image, caps.sticker, caps.video, caps.audio, caps.file]
  pure
    AdvertisedCaps
      { canReply = present,
        canMention = present,
        canMedia = any (\(_, caps, _) -> anyMedia caps) endpoints,
        canReaction = any (\(_, caps, holds) -> caps.reaction && holds) endpoints,
        canFace = any (\(platform, _, _) -> platform == PlatformQQ) endpoints
      }

data IngestOptions = IngestOptions
  { maxRawPayloadBytes :: !Int,
    createDispatch :: !Bool,
    createMirrorDeliveries :: !Bool,
    transcriptKind :: !Text,
    -- | Raw OneBot segment provenance.  Only the QQ adapter may populate it;
    -- every other platform leaves @messages.segments@ as the frozen empty
    -- array and uses canonical content exclusively.
    qqProvenanceSegments :: !(Maybe Value),
    -- | Offer this event only as evidence about an outstanding delivery.  A
    -- match confirms that delivery exactly as an ordinary echo does; no match
    -- stores nothing at all and answers 'EchoUnmatched'.  Adapters whose own
    -- sends come back on the inbound stream use this to prove a
    -- non-idempotent send landed without minting a second copy of the bot's
    -- message whenever the platform's rendering differs from the canonical
    -- body.
    reconcileEchoOnly :: !Bool
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
      reconcileEchoOnly = False
    }

data IngestResult
  = Ingested !NewIngest
  | AlreadyIngested !CanonicalMessageId
  | DeliveryEcho !CanonicalMessageId
  | -- | A 'reconcileEchoOnly' event that matched no delivery.  Nothing was
    -- written, so the caller may drop it.
    EchoUnmatched
  deriving stock (Eq, Show, Generic)

data NewIngest = NewIngest
  { canonicalMessageId :: !CanonicalMessageId,
    -- | The exact canonical IR committed by this transaction.  Returning it
    -- lets adapter-edge observability log a bounded digest without decoding
    -- the row again or retaining the inbound representation.
    canonicalBody :: !(Body 'Canonical),
    dispatchCreated :: !Bool,
    mirrorDeliveriesCreated :: !Int64
  }
  deriving stock (Eq, Show, Generic)

-- | One durable eligibility decision waiting to cross into the live runtime.
-- Content and provenance are canonical; numeric ids remain only as temporary
-- keys for the unchanged session/command runtime, never as content authority.
data DispatchClaim = DispatchClaim
  { canonicalMessageId :: !CanonicalMessageId,
    compatibilityMessageId :: !Int64,
    compatibilityConversationId :: !Int64,
    compatibilityUserId :: !Int64,
    compatibilitySelfId :: !Int64,
    -- | The bot's id /on the origin platform/.  The compatibility self id is
    -- the same number only on QQ; everywhere else it is a synthetic bigint,
    -- so anything deciding "was I mentioned" has to compare against this.
    nativeAccountId :: !NativeAccountId,
    body :: !(Body 'Canonical),
    originEndpointId :: !EndpointId,
    replyToCompatibilityMessageId :: !(Maybe Int64),
    sourcePlatform :: !Platform,
    senderDisplayName :: !(Maybe Text),
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
    canonicalBody :: !(Body 'Ingest),
    replyToCompatibilityMessageId :: !(Maybe Int64)
  }
  deriving stock (Eq, Show)

data EnqueuedOutbound = EnqueuedOutbound
  { canonicalMessageId :: !CanonicalMessageId,
    compatibilityMessageId :: !Int64,
    primaryDeliveryId :: !DeliveryId,
    deliveriesCreated :: !Int64
  }
  deriving stock (Eq, Show, Generic)

-- | A non-text action targeting an existing canonical message.  A required
-- platform is used for platform-native vocabularies such as QQ face ids;
-- generic inbound reactions leave it empty and fan out to every capable
-- endpoint holding a native copy of the target.
data ReactionDraft = ReactionDraft
  { legacyConversationId :: !Int64,
    targetCompatibilityMessageId :: !Int64,
    reactionKey :: !Text,
    reactionAction :: !ReactionAction,
    requiredPlatform :: !(Maybe Platform)
  }
  deriving stock (Eq, Show, Generic)

data EnqueuedReaction = EnqueuedReaction
  { canonicalMessageId :: !CanonicalMessageId,
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
    PlatformEndpointStatus . EndpointId
      <$> field
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
    dcPlatformAccountId :: !Int64,
    dcPlatform :: !Text,
    dcNativeAccountId :: !Text,
    dcNativeConversationId :: !Text,
    dcContent :: !Value,
    dcEventKind :: !Text,
    dcActionTarget :: !(Maybe Text),
    dcReactionKey :: !(Maybe Text),
    dcReactionAdded :: !Bool,
    dcPreviousReactionNative :: !(Maybe Text),
    dcCompatibilityConversationId :: !Int64,
    dcReplyNativeEventId :: !(Maybe Text),
    dcReplyAuthor :: !(Maybe Text),
    dcReplyContent :: !(Maybe Value),
    dcOriginPlatform :: !Text,
    dcSenderDisplayName :: !(Maybe Text),
    dcMessageOrigin :: !Text,
    dcIdempotencyKey :: !Text,
    dcAttemptCount :: !Int,
    dcCapabilities :: !Value
  }

instance FromRow DeliveryClaimRow where
  fromRow =
    DeliveryClaimRow <$> field <*> field <*> field <*> field <*> field <*> field <*> field <*> field <*> field <*> field <*> field <*> field <*> field <*> field <*> field <*> field <*> field <*> field <*> field <*> field <*> field <*> field <*> field

data DispatchClaimRow = DispatchClaimRow
  { dcrCanonicalMessageId :: !Int64,
    dcrMessageId :: !Int64,
    dcrGroupId :: !Int64,
    dcrUserId :: !Int64,
    dcrSelfId :: !Int64,
    dcrNativeAccountId :: !Text,
    dcrContent :: !Value,
    dcrOriginEndpointId :: !Int64,
    dcrReplyToMessageId :: !(Maybe Int64),
    dcrSourcePlatform :: !Text,
    dcrSenderDisplayName :: !(Maybe Text),
    dcrAttemptCount :: !Int
  }

instance FromRow DispatchClaimRow where
  fromRow =
    DispatchClaimRow
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

compatibilityMessageIdForCanonical ::
  (WithConnection :> es, IOE :> es) =>
  CanonicalMessageId ->
  Eff es Int64
compatibilityMessageIdForCanonical (CanonicalMessageId canonical) = do
  rows <- query "SELECT message_id FROM messages WHERE canonical_message_id = ?" (Only canonical)
  pure (exactlyOne "compatibilityMessageIdForCanonical" rows)

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
  OutboundCaps ->
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
    -- A configured mirror may have claimed this conversation before another
    -- endpoint is first observed.  Mirror membership is conversation topology,
    -- never a platform-pair special case.
    _ <-
      execute
        "UPDATE conversation_endpoints current_endpoint \
        \ SET endpoint_mode = 'mirror', updated_at = now() \
        \ WHERE current_endpoint.endpoint_id = ? \
        \   AND EXISTS ( \
        \     SELECT 1 FROM conversation_endpoints peer \
        \     WHERE peer.conversation_id = current_endpoint.conversation_id \
        \       AND peer.endpoint_id <> current_endpoint.endpoint_id \
        \       AND peer.endpoint_mode = 'mirror')"
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
  OutboundCaps ->
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
    -- Attaching any configured mirror is one platform-neutral linking
    -- operation.  Promote all peers in the same transaction so adding a third
    -- platform cannot recreate a half-mirror.
    case (mode, mLegacy) of
      (EndpointMirror, Just _) -> do
        _ <-
          execute
            "UPDATE conversation_endpoints \
            \ SET endpoint_mode = 'mirror', updated_at = now() \
            \ WHERE conversation_id = ?"
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
  -- Sender and mention identities lock in one ascending batch so two
  -- concurrent ingests can never take identity row locks in opposite
  -- orders.
  identities <-
    ensureIdentityBatch
      endpoint
      ( Map.insertWith
          (<|>)
          envelope.senderNativeId
          envelope.senderDisplayName
          (bodyMentionDisplays envelope.content)
      )
  identityId <- case Map.lookup envelope.senderNativeId identities of
    Just identity -> pure identity
    Nothing -> error "ingestEnvelope: sender identity missing from batch"
  resolvedCanonicalBody <- resolveBodyMentions identities envelope.content
  let contentValue = toJSON resolvedCanonicalBody
      NativeEventId nativeEvent = envelope.nativeEventId
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
  reconciled <- reconcileDeliveryEcho endpoint identityId contentValue safeRaw rawTruncated
  case reconciled of
    Just cid -> pure (DeliveryEcho (CanonicalMessageId cid))
    Nothing | options.reconcileEchoOnly -> pure EchoUnmatched
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
          "SELECT canonical_message_id FROM message_deliveries \
          \ WHERE endpoint_id = ? AND native_event_id = ? \
          \   AND idempotency_key NOT LIKE 'source:%' \
          \ FOR UPDATE"
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
          rendered =
            promptCanonicalText
              (parsePlatform endpoint.erPlatform)
              (identityNatives identities)
              resolvedBody
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
      let replyLegacy = snd <$> replyTarget
          replyCanonical = fst <$> replyTarget
      inserted <-
        query
          "INSERT INTO messages \
          \ (message_id, group_id, user_id, self_id, received_at, occurred_at, \
          \  segments, canonical_content, rendered_text, raw_message, sender_nickname, \
          \  reply_to_message_id, reply_to_canonical_message_id, kind, conversation_id, \
          \  author_principal_id, origin_endpoint_id, source_native_event_id, message_origin, source_platform, event_kind) \
          \ SELECT ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, \
          \        pi.principal_id, ?, ?, 'inbound', ?, ? \
          \ FROM principal_identities pi WHERE pi.principal_identity_id = ? \
          \ RETURNING canonical_message_id"
          ( legacyMessage,
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
            identityId
          )
      let cid = exactlyOne "ingestEnvelope message" inserted
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
      let dispatchable = envelope.eventKind == EventMessage && options.createDispatch
      _ <-
        execute
          "INSERT INTO message_dispatches \
          \ (canonical_message_id, status, completed_at) \
          \ VALUES (?, ?, CASE WHEN ?::boolean THEN NULL ELSE now() END)"
          (cid, if dispatchable then ("pending" :: Text) else "ignored", dispatchable)
      forM_ envelope.relations (insertRelation cid envelope.endpointId)
      mirrorCount <-
        if not options.createMirrorDeliveries
          then pure 0
          else case envelope.eventKind of
            EventMessage -> insertMessageMirrors cid envelope.endpointId
            EventEdit -> insertMetaMirrors cid envelope.endpointId ("replace" :: Text) ("edit" :: Text)
            EventReaction -> insertMetaMirrors cid envelope.endpointId ("reaction" :: Text) ("reaction" :: Text)
            EventRedaction -> insertMetaMirrors cid envelope.endpointId ("redacts" :: Text) ("redact" :: Text)
            EventMembership -> pure 0
      pure
        ( Ingested
            NewIngest
              { canonicalMessageId = CanonicalMessageId cid,
                canonicalBody = resolvedBody,
                dispatchCreated = dispatchable,
                mirrorDeliveriesCreated = mirrorCount
              }
        )

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
  let endpointRow =
        EndpointRow
          { erConversationId = conversation,
            erPlatformAccountId = account,
            erPlatform = platformName,
            erNativeAccountId = accountNative,
            erLegacyGroupId = legacyGroup
          }
  identities <-
    ensureIdentityBatch
      endpointRow
      ( Map.insertWith
          (<|>)
          (NativeUserId accountNative)
          (Just "max")
          (bodyMentionDisplays draft.canonicalBody)
      )
  identityId <- case Map.lookup (NativeUserId accountNative) identities of
    Just identity -> pure identity
    Nothing -> error "enqueueOutbound: bot identity missing from batch"
  canonicalBody <- resolveBodyMentions identities draft.canonicalBody
  let renderedProjection =
        promptCanonicalText (parsePlatform platformName) (identityNatives identities) canonicalBody
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
        Jsonb (toJSON ([] :: [Value])),
        Jsonb (toJSON canonicalBody),
        renderedProjection,
        draft.replyToCompatibilityMessageId,
        replyCanonical,
        draft.transcriptKind,
        conversation,
        principal,
        primaryEndpoint,
        "max:" <> T.pack (show canonical),
        platformName
      )
  when (inserted /= 1) (error "enqueueOutbound: canonical insert did not affect one row")
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
      (canonical, canonical, conversation, isNothing draft.sourceCompatibilityMessageId, primaryEndpoint)
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

-- | Record a bot-authored semantic decision that must be visible to future
-- prompts but has no transport side effect (currently the model's explicit
-- silence token).  It uses the same canonical body/identity/relation shape as
-- outbound messages and deliberately creates no delivery row.
recordInternalMessage ::
  (WithConnection :> es, IOE :> es) =>
  OutboundDraft ->
  Eff es CanonicalMessageId
recordInternalMessage draft = withTransaction $ do
  primaryRows <-
    query
      "SELECT e.endpoint_id, e.conversation_id, e.platform_account_id, a.platform, \
      \       a.native_account_id \
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
  (primaryEndpoint, conversation, account, platformName, accountNative) <-
    case primaryRows :: [(Int64, Int64, Int64, Text, Text)] of
      [row] -> pure row
      _ -> error "recordInternalMessage: conversation has no enabled endpoint"
  let endpointRow =
        EndpointRow
          { erConversationId = conversation,
            erPlatformAccountId = account,
            erPlatform = platformName,
            erNativeAccountId = accountNative,
            erLegacyGroupId = Just draft.legacyConversationId
          }
  identities <-
    ensureIdentityBatch
      endpointRow
      ( Map.insertWith
          (<|>)
          (NativeUserId accountNative)
          (Just "max")
          (bodyMentionDisplays draft.canonicalBody)
      )
  identityId <- case Map.lookup (NativeUserId accountNative) identities of
    Just identity -> pure identity
    Nothing -> error "recordInternalMessage: bot identity missing from batch"
  canonicalBody <- resolveBodyMentions identities draft.canonicalBody
  let renderedProjection =
        promptCanonicalText (parsePlatform platformName) (identityNatives identities) canonicalBody
      contentHash = TE.decodeUtf8 (Base16.encode (SHA256.hash (LBS.toStrict (encode canonicalBody))))
      sourceKey =
        "max:internal:"
          <> T.pack (show conversation)
          <> ":"
          <> maybe "none" (T.pack . show) draft.sourceCompatibilityMessageId
          <> ":"
          <> contentHash
  lockRows <-
    query
      "SELECT pg_advisory_xact_lock(hashtextextended(?::text, 0)) IS NULL"
      (Only sourceKey)
  case lockRows :: [Only Bool] of
    [_] -> pure ()
    _ -> error "recordInternalMessage: advisory lock did not return one row"
  existing <-
    query
      "SELECT canonical_message_id FROM messages \
      \ WHERE conversation_id = ? AND message_origin = 'internal' \
      \   AND source_native_event_id = ?"
      (conversation, sourceKey)
  case existing :: [Only Int64] of
    [Only canonical] -> pure (CanonicalMessageId canonical)
    [] -> do
      principalRows <-
        query
          "SELECT principal_id FROM principal_identities WHERE principal_identity_id = ?"
          (Only identityId)
      let principal = exactlyOne "recordInternalMessage principal" (principalRows :: [Only Int64])
      canonicalRows <- query "SELECT nextval('canonical_message_id_seq')" ()
      compatibilityRows <- query "SELECT -nextval('synthetic_message_id_seq')" ()
      let canonical = exactlyOne "recordInternalMessage canonical id" (canonicalRows :: [Only Int64])
          compatibilityMessage = exactlyOne "recordInternalMessage compatibility id" (compatibilityRows :: [Only Int64])
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
          \ VALUES (?, ?, ?, ?, ?, '[]'::jsonb, ?, ?, '', 'max', ?, ?, ?, ?, ?, ?, ?, now(), 'internal', ?)"
          ( canonical,
            compatibilityMessage,
            draft.legacyConversationId,
            compatibilitySelf,
            compatibilitySelf,
            Jsonb (toJSON canonicalBody),
            renderedProjection,
            draft.replyToCompatibilityMessageId,
            replyCanonical,
            draft.transcriptKind,
            conversation,
            principal,
            primaryEndpoint,
            sourceKey,
            platformName
          )
      when (inserted /= 1) (error "recordInternalMessage: canonical insert did not affect one row")
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
      pure (CanonicalMessageId canonical)
    _ -> error "recordInternalMessage: duplicate source key invariant violated"

-- | Publish a reaction action and its capable endpoint copies atomically.
-- Unsupported platforms and targets with no native copy are intentionally a
-- quiet 'Nothing'.  The stable source key makes dispatch retries idempotent:
-- one trigger/key/polarity/platform tuple owns one canonical action row.
enqueueReaction ::
  (WithConnection :> es, IOE :> es) =>
  ReactionDraft ->
  Eff es (Maybe EnqueuedReaction)
enqueueReaction draft = withTransaction $ do
  targetRows <-
    query
      "SELECT m.canonical_message_id, m.conversation_id \
      \ FROM messages m JOIN conversations c USING (conversation_id) \
      \ WHERE c.legacy_group_id = ? AND m.message_id = ?"
      (draft.legacyConversationId, draft.targetCompatibilityMessageId)
  case targetRows :: [(Int64, Int64)] of
    [] -> pure Nothing
    [(targetCanonical, conversation)] -> do
      let requiredName = renderPlatform <$> draft.requiredPlatform
          sourceKey =
            "max:reaction:"
              <> T.pack (show targetCanonical)
              <> ":"
              <> draft.reactionKey
              <> ":"
              <> (case draft.reactionAction of ReactionAdd -> "add"; ReactionRemove -> "remove")
              <> maybe "" (":" <>) requiredName
      lockRows <-
        query
          "SELECT pg_advisory_xact_lock(hashtextextended(?::text, 0)) IS NULL"
          (Only sourceKey)
      case lockRows :: [Only Bool] of
        [_] -> pure ()
        _ -> error "enqueueReaction: advisory lock did not return one row"
      existing <-
        query
          "SELECT m.canonical_message_id, count(d.delivery_id) \
          \ FROM messages m \
          \ LEFT JOIN message_deliveries d USING (canonical_message_id) \
          \ WHERE m.conversation_id = ? AND m.message_origin = 'internal' \
          \   AND m.event_kind = 'reaction' AND m.source_native_event_id = ? \
          \ GROUP BY m.canonical_message_id"
          (conversation, sourceKey)
      case existing :: [(Int64, Int64)] of
        [(canonical, count)] ->
          pure (Just EnqueuedReaction {canonicalMessageId = CanonicalMessageId canonical, deliveriesCreated = count})
        [] -> publish targetCanonical conversation sourceKey requiredName
        _ -> error "enqueueReaction: duplicate internal action invariant violated"
    _ -> error "enqueueReaction: duplicate compatibility target invariant violated"
  where
    publish targetCanonical conversation sourceKey requiredName = do
      endpointCandidates <-
        query
          "SELECT e.endpoint_id, e.platform_account_id, a.platform, a.native_account_id, c.legacy_group_id, \
          \       CASE WHEN e.capabilities = '{}'::jsonb THEN a.capabilities ELSE e.capabilities END \
          \ FROM conversation_endpoints e \
          \ JOIN platform_accounts a USING (platform_account_id) \
          \ JOIN conversations c USING (conversation_id) \
          \ WHERE e.conversation_id = ? AND e.enabled AND a.enabled \
          \   AND (?::text IS NULL OR a.platform = ?) \
          \   AND ( \
          \     EXISTS (SELECT 1 FROM platform_events copy \
          \             WHERE copy.endpoint_id = e.endpoint_id \
          \               AND copy.canonical_message_id = ?) \
          \     OR EXISTS (SELECT 1 FROM message_deliveries copy \
          \                WHERE copy.endpoint_id = e.endpoint_id \
          \                  AND copy.canonical_message_id = ? \
          \                  AND copy.native_event_id IS NOT NULL) \
          \   ) \
          \ ORDER BY CASE a.platform WHEN 'qq' THEN 0 ELSE 1 END, e.endpoint_id"
          (conversation, requiredName, requiredName, targetCanonical, targetCanonical)
      let endpointRows =
            [ (endpoint, account, platformName, accountNative, legacyGroup)
            | (endpoint, account, platformName, accountNative, legacyGroup, manifest) <-
                (endpointCandidates :: [(Int64, Int64, Text, Text, Maybe Int64, Value)]),
              (outboundCapsFromValue manifest).reaction
            ]
      case endpointRows of
        [] -> pure Nothing
        rows@((originEndpoint, account, platformName, accountNative, legacyGroup) : _) -> do
          let endpointRow =
                EndpointRow
                  { erConversationId = conversation,
                    erPlatformAccountId = account,
                    erPlatform = platformName,
                    erNativeAccountId = accountNative,
                    erLegacyGroupId = legacyGroup
                  }
          identity <- ensurePrincipalIdentity endpointRow (NativeUserId accountNative) (Just "max")
          principalRows <-
            query
              "SELECT principal_id FROM principal_identities WHERE principal_identity_id = ?"
              (Only identity)
          let principal = exactlyOne "enqueueReaction principal" (principalRows :: [Only Int64])
          canonicalRows <- query "SELECT nextval('canonical_message_id_seq')" ()
          compatibilityRows <- query "SELECT -nextval('synthetic_message_id_seq')" ()
          let canonical = exactlyOne "enqueueReaction canonical id" (canonicalRows :: [Only Int64])
              compatibilityMessage = exactlyOne "enqueueReaction compatibility id" (compatibilityRows :: [Only Int64])
              endpointIds = PGArray [endpoint | (endpoint, _, _, _, _) <- rows]
              reactionAdded = draft.reactionAction == ReactionAdd
              body = toJSON (Body [] :: Body 'Canonical)
          compatibilitySelf <- compatibilityId platformName "user" accountNative
          inserted <-
            execute
              "INSERT INTO messages \
              \ (canonical_message_id, message_id, group_id, user_id, self_id, segments, canonical_content, \
              \  rendered_text, raw_message, sender_nickname, kind, conversation_id, author_principal_id, \
              \  origin_endpoint_id, source_native_event_id, occurred_at, message_origin, source_platform, event_kind) \
              \ VALUES (?, ?, ?, ?, ?, '[]'::jsonb, ?, '', '', 'max', 'debug', ?, ?, ?, ?, now(), \
              \         'internal', ?, 'reaction')"
              ( canonical,
                compatibilityMessage,
                draft.legacyConversationId,
                compatibilitySelf,
                compatibilitySelf,
                Jsonb body,
                conversation,
                principal,
                originEndpoint,
                sourceKey,
                platformName
              )
          when (inserted /= 1) (error "enqueueReaction: canonical insert did not affect one row")
          _ <-
            execute
              "INSERT INTO message_relations \
              \ (canonical_message_id, relation_kind, target_canonical_message_id, reaction_key, reaction_added) \
              \ VALUES (?, 'reaction', ?, ?, ?)"
              (canonical, targetCanonical, draft.reactionKey, reactionAdded)
          _ <-
            execute
              "INSERT INTO message_dispatches (canonical_message_id, status, completed_at) \
              \ VALUES (?, 'ignored', now())"
              (Only canonical)
          deliveryCount <-
            execute
              "INSERT INTO message_deliveries \
              \ (canonical_message_id, endpoint_id, status, idempotency_key) \
              \ SELECT ?, endpoint_id, 'pending', \
              \        'reaction:' || ?::text || ':' || endpoint_id::text \
              \ FROM conversation_endpoints WHERE endpoint_id = ANY(?) \
              \ ON CONFLICT (canonical_message_id, endpoint_id) DO NOTHING"
              (canonical, canonical, endpointIds)
          pure
            ( Just
                EnqueuedReaction
                  { canonicalMessageId = CanonicalMessageId canonical,
                    deliveriesCreated = deliveryCount
                  }
            )

metaCapabilityEnabled :: Text -> OutboundCaps -> Bool
metaCapabilityEnabled capability = case capability of
  "edit" -> (.edit)
  "reaction" -> (.reaction)
  "redact" -> (.redact)
  _ -> const False

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
      \       origin_account.native_account_id, \
      \       m.canonical_content, m.origin_endpoint_id, m.reply_to_message_id, \
      \       m.source_platform, m.sender_nickname, c.attempt_count \
      \FROM claimed c \
      \JOIN messages m USING (canonical_message_id) \
      \JOIN conversation_endpoints origin_endpoint \
      \  ON origin_endpoint.endpoint_id = m.origin_endpoint_id \
      \JOIN platform_accounts origin_account \
      \  ON origin_account.platform_account_id = origin_endpoint.platform_account_id \
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
  -- | stable worker id
  Text ->
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

-- | A worker can disappear after durably claiming a non-idempotent send but
-- before recording the transport outcome.  Retrying that row could duplicate
-- a message, while leaving it as @sending@ forever blocks every later ordered
-- delivery on the endpoint.  Once the ownership lease expires, quarantine it
-- as outcome-unknown: visible to operators and echo reconciliation, excluded
-- from automatic retry.
expiredSendingDeliverySql :: Query
expiredSendingDeliverySql =
  "UPDATE message_deliveries \
  \ SET status = 'outcome_unknown', \
  \     lease_owner = NULL, lease_expires_at = NULL, \
  \     last_error = COALESCE(last_error, \
  \       'delivery lease expired before the transport outcome was recorded'), \
  \     updated_at = now() \
  \ WHERE status = 'sending' \
  \   AND (lease_expires_at IS NULL OR lease_expires_at < now())"

-- | Resolve canonical mention identities to native ids on the destination
-- endpoint.  The result is captured before calling the pure lowering
-- function; transports never perform identity lookups or guess from origin
-- ids.  A principal with multiple identities on one account resolves to the
-- mentioned identity itself when it lives on this account, and otherwise to
-- the most recently updated one deterministically — so a copy delivered back
-- to the origin endpoint reproduces the id the author actually wrote.
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

claimDeliveriesWhere ::
  (WithConnection :> es, IOE :> es) =>
  Text ->
  Maybe Int64 ->
  Int ->
  NominalDiffTime ->
  Eff es [DeliveryClaim]
claimDeliveriesWhere workerId mDelivery limit leaseDuration = do
  -- This sweep is deliberately separate from the claim statement: sibling
  -- data-modifying CTEs share a snapshot and would leave the quarantined row
  -- visible as @sending@ to the ordering predicate until the next poll.
  _ <- execute expiredSendingDeliverySql ()
  rows <-
    query
      "WITH candidates AS ( \
      \ SELECT d.delivery_id FROM message_deliveries d \
      \ JOIN conversation_endpoints e ON e.endpoint_id = d.endpoint_id AND e.enabled \
      \ JOIN platform_accounts a ON a.platform_account_id = e.platform_account_id AND a.enabled \
      \ JOIN messages candidate_message ON candidate_message.canonical_message_id = d.canonical_message_id \
      \ WHERE d.status IN ('pending', 'failed') \
      \   AND d.next_attempt_at <= now() \
      \   AND (d.lease_expires_at IS NULL OR d.lease_expires_at < now()) \
      \   AND (?::bigint IS NULL OR d.delivery_id = ?) \
      \   AND NOT EXISTS ( \
      \     SELECT 1 FROM message_deliveries earlier \
      \     JOIN messages earlier_message ON earlier_message.canonical_message_id = earlier.canonical_message_id \
      \     WHERE earlier.endpoint_id = d.endpoint_id \
      \       AND earlier.delivery_id <> d.delivery_id \
      \       AND earlier.status IN ('pending', 'failed', 'sending') \
      \       AND (earlier_message.conversation_seq, earlier.delivery_id) \
      \           < (candidate_message.conversation_seq, d.delivery_id) \
      \   ) \
      \ ORDER BY candidate_message.conversation_seq, d.delivery_id \
      \ FOR UPDATE OF d SKIP LOCKED LIMIT ? \
      \), claimed AS ( \
      \ UPDATE message_deliveries d \
      \ SET status = 'sending', lease_owner = ?, \
      \     lease_expires_at = now() + (?::double precision * interval '1 second'), \
      \     attempt_count = attempt_count + 1, last_attempt_at = now(), updated_at = now() \
      \ FROM candidates c WHERE d.delivery_id = c.delivery_id \
      \ RETURNING d.* \
      \) \
      \ SELECT c.delivery_id, c.canonical_message_id, c.endpoint_id, a.platform_account_id, a.platform, \
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
      \ FROM claimed c \
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
      \     FROM message_deliveries target_delivery \
      \     WHERE target_delivery.endpoint_id = c.endpoint_id \
      \       AND target_delivery.native_event_id IS NOT NULL \
      \       AND (target_delivery.canonical_message_id = action_relation.target_canonical_message_id \
      \            OR (action_relation.target_canonical_message_id IS NULL \
      \                AND target_delivery.native_event_id = action_relation.target_native_event_id)) \
      \   ) copies \
      \   ORDER BY copies.source_rank, copies.copied_at DESC, copies.copy_id DESC LIMIT 1 \
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
      \     JOIN message_deliveries prior_delivery \
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
      \     FROM message_deliveries target_delivery \
      \     WHERE target_delivery.endpoint_id = c.endpoint_id \
      \       AND target_delivery.native_event_id IS NOT NULL \
      \       AND (target_delivery.canonical_message_id = reply_relation.target_canonical_message_id \
      \            OR target_delivery.native_event_id = reply_relation.target_native_event_id) \
      \   ) copies \
      \   ORDER BY copies.source_rank, copies.copied_at DESC, copies.copy_id DESC LIMIT 1 \
      \ ) reply_copy ON true \
      \ ORDER BY c.delivery_id"
      (mDelivery, mDelivery, limit, workerId, realToFrac leaseDuration :: Double)
  pure (toClaim <$> (rows :: [DeliveryClaimRow]))

completeDelivery ::
  (WithConnection :> es, IOE :> es) =>
  Text ->
  DeliveryId ->
  [LowerNote] ->
  DeliveryCompletion ->
  Eff es Bool
completeDelivery workerId (DeliveryId delivery) lowerNotes completion = do
  withTransaction $ do
    safeCompletion <- discardOwnedNativeEvent completion
    changed <- case safeCompletion of
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
          \ JOIN message_deliveries owner ON owner.endpoint_id = target.endpoint_id\
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
        \ WHERE delivery_id = ? AND status = 'sending' AND lease_owner = ?"
        ( status,
          unNativeEventId <$> native,
          Jsonb (toJSON lowerNotes),
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
      content = Body (sanitizeIngestNode <$> envelope.content.nodes),
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
      qqProvenanceSegments = sanitizePostgresValue <$> options.qqProvenanceSegments
    }

sanitizeNativeUserId :: NativeUserId -> NativeUserId
sanitizeNativeUserId (NativeUserId native) = NativeUserId (sanitizePostgresText native)

sanitizeNativeEventId :: NativeEventId -> NativeEventId
sanitizeNativeEventId (NativeEventId native) = NativeEventId (sanitizePostgresText native)

sanitizeRelation :: MessageRelation -> MessageRelation
sanitizeRelation = \case
  ReplyTo native -> ReplyTo (sanitizeNativeEventId native)
  Replaces native -> Replaces (sanitizeNativeEventId native)
  Redacts native -> Redacts (sanitizeNativeEventId native)
  ReactsTo native reaction action ->
    ReactsTo (sanitizeNativeEventId native) (sanitizePostgresText reaction) action
  ContainedIn native position ->
    ContainedIn (sanitizeNativeEventId native) (max 0 position)

sanitizeIngestNode :: Node 'Ingest -> Node 'Ingest
sanitizeIngestNode = \case
  NText body -> NText (sanitizePostgresText body)
  NMention native display ->
    NMention (sanitizeNativeUserId native) (sanitizePostgresText display)
  NEmote emote ->
    NEmote
      Emote
        { origin = emote.origin,
          nativeId = sanitizePostgresText emote.nativeId,
          name = sanitizePostgresText <$> emote.name,
          raw = sanitizePostgresValue <$> emote.raw
        }
  NMedia source meta ->
    NMedia
      (sanitizeMediaRef <$> source)
      MediaMeta
        { kind = meta.kind,
          mime = sanitizePostgresText <$> meta.mime,
          sizeBytes = meta.sizeBytes,
          name = sanitizePostgresText <$> meta.name,
          description = sanitizePostgresText <$> meta.description,
          raw = sanitizePostgresValue <$> meta.raw
        }
  NCard card ->
    NCard
      Card
        { title = sanitizePostgresText <$> card.title,
          subtitle = sanitizePostgresText <$> card.subtitle,
          url = sanitizePostgresText <$> card.url,
          tag = sanitizePostgresText <$> card.tag,
          preview = sanitizeMediaRef <$> card.preview,
          raw = sanitizePostgresValue <$> card.raw
        }
  NForward forward ->
    NForward
      ForwardRef
        { nativeId = sanitizePostgresText forward.nativeId,
          count = forward.count
        }
  NUnsupported unsupported ->
    NUnsupported
      Unsupported
        { source = sanitizePostgresText unsupported.source,
          description = sanitizePostgresText unsupported.description,
          raw = sanitizePostgresValue <$> unsupported.raw
        }

sanitizeMediaRef :: MediaRef -> MediaRef
sanitizeMediaRef ref =
  fromMaybe
    (error "sanitizeMediaRef: validated reference became invalid")
    (parseMediaRef (sanitizePostgresText (renderMediaRef ref)))

-- | Ensure principal identities for a batch of native users in ascending
-- native-id order.  Every caller that takes identity row locks must go
-- through one sorted batch per transaction, so concurrent transactions
-- cannot acquire FOR UPDATE locks in opposite orders.
ensureIdentityBatch ::
  (WithConnection :> es, IOE :> es) =>
  EndpointRow ->
  Map NativeUserId (Maybe Text) ->
  Eff es (Map NativeUserId Int64)
ensureIdentityBatch endpoint =
  Map.traverseWithKey (ensurePrincipalIdentity endpoint)

-- | The mention resolution the canonical prompt projection needs, read back
-- from the identity batch this transaction already ensured.
--
-- Every writer renders @rendered_text@ from the /resolved/ canonical body,
-- never from the pre-identity ingest body: the two disagree exactly where
-- 'resolveBodyMentions' enriched a bare native id into a stored display name,
-- and @maintenance verify@/@reproject@ recompute from the canonical body.
-- Rendering from the ingest body is what made a correct row look stale.
identityNatives :: Map NativeUserId Int64 -> Map PrincipalIdentityId NativeUserId
identityNatives identities =
  Map.fromList
    [ (PrincipalIdentityId identity, native)
    | (native, identity) <- Map.toList identities
    ]

-- | The identity work one ingest body needs, keyed for one sorted batch.
-- A display is kept only when it says more than the id itself.
bodyMentionDisplays :: Body 'Ingest -> Map NativeUserId (Maybe Text)
bodyMentionDisplays body =
  Map.fromListWith
    (<|>)
    [(native, meaningfulDisplay native display) | NMention native display <- body.nodes]

meaningfulDisplay :: NativeUserId -> Text -> Maybe Text
meaningfulDisplay (NativeUserId native) display =
  let stripped = T.strip display
   in if T.null stripped || stripped == native then Nothing else Just stripped

-- | Turn an adapter's ingest body into the stored canonical phase using a
-- pre-ensured identity table.  A display that is blank or just the native
-- id is enriched from the stored identity when one carries a name, so a
-- bare QQ at-segment can still mirror as a readable @nickname.
resolveBodyMentions ::
  (WithConnection :> es, IOE :> es) =>
  Map NativeUserId Int64 ->
  Body 'Ingest ->
  Eff es (Body 'Canonical)
resolveBodyMentions identities = resolveIngest resolve
  where
    resolve native@(NativeUserId nativeText) display = do
      identity <- case Map.lookup native identities of
        Just identity -> pure identity
        Nothing -> error "resolveBodyMentions: mention missing from identity batch"
      finalDisplay <- case meaningfulDisplay native display of
        Just meaningful -> pure meaningful
        Nothing -> do
          rows <-
            query
              "SELECT display_name FROM principal_identities WHERE principal_identity_id = ?"
              (Only identity)
          pure $ case rows :: [Only (Maybe Text)] of
            [Only (Just name)] | isJust (meaningfulDisplay native name) -> name
            _ -> nativeText
      pure (MentionIdentity (PrincipalIdentityId identity), finalDisplay)

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
  let native = NativeUserId nativeUser
      freshDisplay = display >>= meaningfulDisplay native
  (existing :: [(Int64, Int64, Maybe Text)]) <-
    query
      "SELECT principal_identity_id, principal_id, display_name FROM principal_identities \
      \ WHERE platform_account_id = ? AND native_user_id = ? FOR UPDATE"
      (endpoint.erPlatformAccountId, nativeUser)
  case existing of
    [(identity, principal, storedDisplay)] -> enrich identity principal storedDisplay
    [] -> do
      principalRows <-
        query
          "INSERT INTO principals (display_name) VALUES (?) RETURNING principal_id"
          (Only freshDisplay)
      let principal = exactlyOne "ensurePrincipalIdentity principal" (principalRows :: [Only Int64])
      inserted <-
        query
          "INSERT INTO principal_identities \
          \ (principal_id, platform_account_id, native_user_id, display_name) \
          \ VALUES (?, ?, ?, ?) \
          \ ON CONFLICT (platform_account_id, native_user_id) DO NOTHING \
          \ RETURNING principal_identity_id"
          (principal, endpoint.erPlatformAccountId, nativeUser, freshDisplay)
      case (inserted :: [Only Int64]) of
        [Only identity] -> pure identity
        [] -> do
          _ <- execute "DELETE FROM principals WHERE principal_id = ?" (Only principal)
          (winner :: [(Int64, Int64, Maybe Text)]) <-
            query
              "SELECT principal_identity_id, principal_id, display_name FROM principal_identities \
              \ WHERE platform_account_id = ? AND native_user_id = ?"
              (endpoint.erPlatformAccountId, nativeUser)
          case winner of
            [(identity, winnerPrincipal, storedDisplay)] -> enrich identity winnerPrincipal storedDisplay
            _ -> error "ensurePrincipalIdentity winner: expected exactly one row"
        _ -> error "ensurePrincipalIdentity: multiple inserted identities"
    _ -> error "ensurePrincipalIdentity: duplicate identity invariant violated"
  where
    enrich identity principal storedDisplay = do
      case (display >>= meaningfulDisplay (NativeUserId nativeUser), storedDisplay >>= meaningfulDisplay (NativeUserId nativeUser)) of
        (Just better, Nothing) -> do
          _ <-
            execute
              "UPDATE principal_identities SET display_name = ? \
              \ WHERE principal_identity_id = ?"
              (better, identity)
          _ <-
            execute
              "UPDATE principals SET display_name = ? \
              \ WHERE principal_id = ? \
              \   AND (display_name IS NULL OR btrim(display_name) = '' OR display_name = ?)"
              (better, principal, nativeUser)
          pure identity
        _ -> pure identity

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
        "SELECT target.canonical_message_id, target.message_id FROM ( \
        \ SELECT m.canonical_message_id, m.message_id, 0 AS source_rank, \
        \        pe.occurred_at AS copied_at, pe.platform_event_id AS copy_id \
        \ FROM platform_events pe \
        \ JOIN messages m USING (canonical_message_id) \
        \ WHERE pe.endpoint_id = ? AND pe.native_event_id = ? \
        \ UNION ALL \
        \ SELECT m.canonical_message_id, m.message_id, 1 AS source_rank, \
        \        d.updated_at AS copied_at, d.delivery_id AS copy_id \
        \ FROM message_deliveries d \
        \ JOIN messages m USING (canonical_message_id) \
        \ WHERE d.endpoint_id = ? AND d.native_event_id = ? \
        \ ) target \
        \ ORDER BY target.source_rank, target.copied_at DESC, target.copy_id DESC \
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
  let (kind, targetNative, reaction, reactionAdded, position) = case relation of
        ReplyTo (NativeEventId target) -> ("reply" :: Text, target, Nothing, True, Nothing)
        Replaces (NativeEventId target) -> ("replace", target, Nothing, True, Nothing)
        Redacts (NativeEventId target) -> ("redacts", target, Nothing, True, Nothing)
        ReactsTo (NativeEventId target) key action ->
          ("reaction", target, Just key, action == ReactionAdd, Nothing)
        ContainedIn (NativeEventId target) childPosition ->
          ("contained_in", target, Nothing, True, Just childPosition)
  resolved <- resolveNativeTarget endpoint targetNative
  _ <-
    execute
      "INSERT INTO message_relations \
      \ (canonical_message_id, relation_kind, target_canonical_message_id, target_native_event_id, reaction_key, reaction_added, relation_position) \
      \ VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT DO NOTHING"
      (cid, kind, resolved, targetNative, reaction, reactionAdded, position)
  pure ()

resolveNativeTarget ::
  (WithConnection :> es, IOE :> es) =>
  EndpointId ->
  Text ->
  Eff es (Maybe Int64)
resolveNativeTarget (EndpointId endpoint) target = do
  rows <-
    query
      "SELECT target.canonical_message_id FROM ( \
      \ SELECT canonical_message_id, 0 AS source_rank, occurred_at AS copied_at, \
      \        platform_event_id AS copy_id \
      \ FROM platform_events \
      \ WHERE endpoint_id = ? AND native_event_id = ? AND canonical_message_id IS NOT NULL \
      \ UNION ALL \
      \ SELECT canonical_message_id, 1 AS source_rank, updated_at AS copied_at, \
      \        delivery_id AS copy_id \
      \ FROM message_deliveries \
      \ WHERE endpoint_id = ? AND native_event_id = ? \
      \ ) target \
      \ ORDER BY target.source_rank, target.copied_at DESC, target.copy_id DESC \
      \ LIMIT 1"
      (endpoint, target, endpoint, target)
  pure (fromOnly <$> listToMaybe rows)

exactlyOne :: String -> [Only a] -> a
exactlyOne _ [Only value] = value
exactlyOne label _ = error (label <> ": expected exactly one row")

toClaim :: DeliveryClaimRow -> DeliveryClaim
toClaim row =
  let destination = parsePlatform row.dcPlatform
      origin = parsePlatform row.dcOriginPlatform
      replyBody = decodeCanonical "reply canonical_content" <$> row.dcReplyContent
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
   in DeliveryClaim
        { deliveryId = DeliveryId row.dcDeliveryId,
          canonicalMessageId = CanonicalMessageId row.dcCanonicalMessageId,
          endpointId = EndpointId row.dcEndpointId,
          platformAccountId = PlatformAccountId row.dcPlatformAccountId,
          platform = destination,
          nativeAccountId = NativeAccountId row.dcNativeAccountId,
          nativeConversationId = NativeConversationId row.dcNativeConversationId,
          body = decodeCanonical "canonical_content" row.dcContent,
          eventKind = parseEventKind row.dcEventKind,
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

decodeCanonical :: String -> Value -> Body 'Canonical
decodeCanonical label value = case fromJSON value of
  Success body -> body
  Error err -> error (label <> ": " <> err)

toDispatchClaim :: DispatchClaimRow -> DispatchClaim
toDispatchClaim row =
  DispatchClaim
    { canonicalMessageId = CanonicalMessageId row.dcrCanonicalMessageId,
      compatibilityMessageId = row.dcrMessageId,
      compatibilityConversationId = row.dcrGroupId,
      compatibilityUserId = row.dcrUserId,
      compatibilitySelfId = row.dcrSelfId,
      nativeAccountId = NativeAccountId row.dcrNativeAccountId,
      body = decodeCanonical "dispatch canonical_content" row.dcrContent,
      originEndpointId = EndpointId row.dcrOriginEndpointId,
      replyToCompatibilityMessageId = row.dcrReplyToMessageId,
      sourcePlatform = parsePlatform row.dcrSourcePlatform,
      senderDisplayName = row.dcrSenderDisplayName,
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

parseEventKind :: Text -> EventKind
parseEventKind = \case
  "message" -> EventMessage
  "edit" -> EventEdit
  "reaction" -> EventReaction
  "redaction" -> EventRedaction
  "membership" -> EventMembership
  other -> error ("unknown canonical event kind: " <> T.unpack other)

capabilitiesValue :: OutboundCaps -> Value
capabilitiesValue = outboundCapsToValue
