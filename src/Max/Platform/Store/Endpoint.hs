{-# LANGUAGE DeriveGeneric #-}

module Max.Platform.Store.Endpoint
  ( EndpointRegistration (..),
    RegisteredEndpoint (..),
    EndpointRow (..),
    createConversation,
    platformForLegacyConversation,
    platformForLegacyMessage,
    registerEndpoint,
    ensureLegacyEndpoint,
    ensureConfiguredEndpoint,
    fetchEndpoint,
  )
where

import Control.Monad (forM, void, when)
import Data.Aeson (Value)
import Data.Int (Int64)
import Data.Maybe (listToMaybe)
import Data.Text (Text)
import Database.PostgreSQL.Simple.FromRow (FromRow (..), field)
import Database.PostgreSQL.Simple.Types (Only (..))
import Effectful (Eff, IOE, type (:>))
import Effectful.PostgreSQL (WithConnection, execute, query)
import GHC.Generics (Generic)
import Max.DB.Codec (Jsonb (..), exactlyOne)
import Max.DB.PlatformIds (compatibilityId)
import Max.DB.Transaction (withTransaction)
import Max.IR.Lower (OutboundCaps, outboundCapsToValue)
import Max.Platform.Types
  ( ConversationId (..),
    ConversationKind (..),
    EndpointId (EndpointId),
    EndpointMode (..),
    NativeAccountId (NativeAccountId),
    NativeConversationId (NativeConversationId),
    Platform,
    PlatformAccountId (PlatformAccountId),
    renderPlatform,
  )

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

data EndpointRow = EndpointRow
  { erEndpointId :: !Int64,
    erConversationId :: !Int64,
    erPlatformAccountId :: !Int64,
    erPlatform :: !Text,
    erNativeAccountId :: !Text,
    erLegacyGroupId :: !(Maybe Int64)
  }

instance FromRow EndpointRow where
  fromRow = do
    erEndpointId <- field
    erConversationId <- field
    erPlatformAccountId <- field
    erPlatform <- field
    erNativeAccountId <- field
    erLegacyGroupId <- field
    pure
      EndpointRow
        { erEndpointId,
          erConversationId,
          erPlatformAccountId,
          erPlatform,
          erNativeAccountId,
          erLegacyGroupId
        }

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
    -- Match legacy registration and ingest: conversation before timeline
    -- notifications, including the account metadata update below.
    targetConversation <- forM mLegacy $ \legacy -> do
      rows <-
        query
          "INSERT INTO conversations (conversation_kind, legacy_group_id) VALUES (?, ?) \
          \ ON CONFLICT (legacy_group_id) DO UPDATE \
          \ SET conversation_kind = EXCLUDED.conversation_kind \
          \ RETURNING conversation_id"
          (renderConversationKind kind, legacy)
      pure (exactlyOne "ensureConfiguredEndpoint target" rows)
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
      -- Rebind existing standalone endpoints when configured as mirrors.
      -- Their past messages remain in the original conversation.
      [(endpointId', conversationId')] -> case targetConversation of
        Nothing -> pure (endpointId', conversationId')
        Just target -> do
          when (target /= conversationId') $
            void $
              execute
                "UPDATE conversation_endpoints SET conversation_id = ?, updated_at = now() \
                \ WHERE endpoint_id = ?"
                (target, endpointId')
          pure (endpointId', target)
      [] -> do
        conversationId' <- case targetConversation of
          Just target -> pure target
          Nothing -> do
            rows <- query "INSERT INTO conversations (conversation_kind) VALUES (?) RETURNING conversation_id" (Only (renderConversationKind kind))
            pure (exactlyOne "ensureConfiguredEndpoint conversation" rows)
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

fetchEndpoint ::
  (WithConnection :> es, IOE :> es) =>
  EndpointId ->
  Eff es EndpointRow
fetchEndpoint (EndpointId endpoint) = do
  rows <-
    query
      "SELECT e.endpoint_id, e.conversation_id, e.platform_account_id, a.platform, a.native_account_id, \
      \       c.legacy_group_id \
      \FROM conversation_endpoints e \
      \JOIN platform_accounts a USING (platform_account_id) \
      \JOIN conversations c USING (conversation_id) \
      \WHERE e.endpoint_id = ? AND e.enabled AND a.enabled"
      (Only endpoint)
  case rows of
    [row] -> pure row
    _ -> error "ingestEnvelope: unknown or disabled endpoint"

renderConversationKind :: ConversationKind -> Text
renderConversationKind = \case
  ConversationGroup -> "group"
  ConversationDirect -> "direct"

renderEndpointMode :: EndpointMode -> Text
renderEndpointMode = \case
  EndpointStandalone -> "standalone"
  EndpointMirror -> "mirror"

capabilitiesValue :: OutboundCaps -> Value
capabilitiesValue = outboundCapsToValue
