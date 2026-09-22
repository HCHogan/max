{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}

module Max.Platform.Store.Conversation
  ( conversationRoster,
    conversationAdvertisedCaps,
    PlatformEndpointStatus (..),
    listPlatformStatus,
    ConversationSummary (..),
    listConversations,
    rememberConversationTitle,
  )
where

import Control.Monad (void)
import Data.Aeson (ToJSON, Value)
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime)
import Database.PostgreSQL.Simple.FromRow (FromRow (..), field)
import Database.PostgreSQL.Simple.Types (Only (Only, fromOnly))
import Effectful (Eff, IOE, type (:>))
import Effectful.PostgreSQL (WithConnection, execute, query)
import GHC.Generics (Generic)
import Max.Conversation.Roster
  ( ConversationRoster (..),
    RosterIdentity (..),
  )
import Max.IR.Lower
  ( OutboundCaps (..),
    Tier (TierDrop),
    outboundCapsFromValue,
  )
import Max.Platform.Types
  ( AdvertisedCaps (..),
    ConversationId (ConversationId),
    EndpointId (EndpointId),
    Platform (PlatformQQ),
    PrincipalId (PrincipalId),
    parsePlatform,
  )

-- | Roster from identities seen in the conversation's endpoints. Native
-- rosters may add silent members, joining by native ID rather than replacing
-- these identities. crPlatforms also includes endpoints with no speakers yet.
conversationRoster ::
  (WithConnection :> es, IOE :> es) =>
  Int64 ->
  Eff es ConversationRoster
conversationRoster legacyConversation = do
  platforms <-
    query
      "SELECT DISTINCT a.platform \
      \ FROM conversations c \
      \ JOIN conversation_endpoints e USING (conversation_id) \
      \ JOIN platform_accounts a USING (platform_account_id) \
      \ WHERE c.legacy_group_id = ? AND e.enabled AND a.enabled"
      (Only legacyConversation)
  rows <-
    query
      "SELECT DISTINCT pi.principal_id, a.platform, pi.native_user_id, pi.display_name \
      \ FROM conversations c \
      \ JOIN conversation_endpoints e USING (conversation_id) \
      \ JOIN platform_accounts a USING (platform_account_id) \
      \ JOIN endpoint_known_identities known ON known.endpoint_id=e.endpoint_id \
      \ JOIN principal_identities pi ON pi.principal_identity_id=known.principal_identity_id AND pi.platform_account_id=a.platform_account_id \
      \ WHERE c.legacy_group_id = ? AND e.enabled AND a.enabled \
      \ ORDER BY pi.principal_id, a.platform, pi.native_user_id, pi.display_name"
      (Only legacyConversation)
  pure
    ConversationRoster
      { crPlatforms = map (parsePlatform . fromOnly) platforms,
        crIdentities =
          [ RosterIdentity
              { riPrincipalId = PrincipalId principal,
                riPlatform = parsePlatform platform,
                riNativeUserId = native,
                riDisplayName = name
              }
          | (principal, platform, native, name) <- rows :: [(Int64, Text, Text, Maybe Text)]
          ]
      }

-- | Derive the semantic surface advertised to the model.  Content actions
-- are enabled when they have a total lowering path; joining a text-only
-- endpoint therefore cannot hide reply, mention or media.  Reactions and QQ
-- faces remain gated because they have no textual action equivalent.
conversationAdvertisedCaps ::
  (WithConnection :> es, IOE :> es) =>
  Int64 ->
  Maybe Int64 ->
  Eff es AdvertisedCaps
conversationAdvertisedCaps legacyConversation targetCanonicalMessage = do
  rows <-
    query
      "SELECT a.platform, CASE WHEN e.capabilities = '{}'::jsonb THEN a.capabilities ELSE e.capabilities END, \
      \       (?::bigint IS NULL OR EXISTS ( \
      \          SELECT 1 FROM messages target \
      \          WHERE target.conversation_id = c.conversation_id AND target.canonical_message_id = ? \
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
      (targetCanonicalMessage, targetCanonicalMessage, legacyConversation)
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
    permanentFailureDeliveries :: !Int64,
    suppressedDeliveries :: !Int64,
    oldestPendingAt :: !(Maybe UTCTime),
    lastDeliveryAt :: !(Maybe UTCTime)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

instance FromRow PlatformEndpointStatus where
  fromRow = do
    endpointId <- EndpointId <$> field
    conversationId <- ConversationId <$> field
    legacyConversationId <- field
    platform <- field
    nativeAccountId <- field
    nativeConversationId <- field
    endpointMode <- field
    enabled <- field
    capabilities <- field
    cursors <- field
    lastInboundAt <- field
    pendingDeliveries <- field
    failedDeliveries <- field
    acceptedUnconfirmedDeliveries <- field
    outcomeUnknownDeliveries <- field
    permanentFailureDeliveries <- field
    suppressedDeliveries <- field
    oldestPendingAt <- field
    lastDeliveryAt <- field
    pure
      PlatformEndpointStatus
        { endpointId,
          conversationId,
          legacyConversationId,
          platform,
          nativeAccountId,
          nativeConversationId,
          endpointMode,
          enabled,
          capabilities,
          cursors,
          lastInboundAt,
          pendingDeliveries,
          failedDeliveries,
          acceptedUnconfirmedDeliveries,
          outcomeUnknownDeliveries,
          permanentFailureDeliveries,
          suppressedDeliveries,
          oldestPendingAt,
          lastDeliveryAt
        }

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
    \       (SELECT count(*) FROM message_deliveries d WHERE d.endpoint_id = e.endpoint_id AND d.status IN ('pending', 'reserved', 'sending')), \
    \       (SELECT count(*) FROM message_deliveries d WHERE d.endpoint_id = e.endpoint_id AND d.status = 'failed'), \
    \       (SELECT count(*) FROM message_deliveries d WHERE d.endpoint_id = e.endpoint_id AND d.status = 'accepted_unconfirmed'), \
    \       (SELECT count(*) FROM message_deliveries d WHERE d.endpoint_id = e.endpoint_id AND d.status = 'outcome_unknown'), \
    \       (SELECT count(*) FROM message_deliveries d WHERE d.endpoint_id = e.endpoint_id AND d.status = 'permanent_failure'), \
    \       (SELECT count(*) FROM message_deliveries d WHERE d.endpoint_id = e.endpoint_id AND d.status = 'suppressed'), \
    \       (SELECT min(d.created_at) FROM message_deliveries d WHERE d.endpoint_id = e.endpoint_id AND d.status IN ('pending', 'reserved', 'sending', 'failed')), \
    \       (SELECT max(d.updated_at) FROM message_deliveries d WHERE d.endpoint_id = e.endpoint_id) \
    \ FROM conversation_endpoints e \
    \ JOIN platform_accounts a USING (platform_account_id) \
    \ JOIN conversations c USING (conversation_id) \
    \ ORDER BY e.conversation_id, e.endpoint_id"
    ()

-- | Conversation-picker row: latest activity plus the learned or endpoint title.
data ConversationSummary = ConversationSummary
  { csConversationId :: !Int64,
    csLegacyGroupId :: !(Maybe Int64),
    csKind :: !Text,
    csTitle :: !(Maybe Text),
    csPlatforms :: !(Maybe Text),
    csEndpoints :: !Int64,
    csMessageCount :: !Int64,
    csLastMessageAt :: !(Maybe UTCTime)
  }
  deriving stock (Eq, Show)

instance FromRow ConversationSummary where
  fromRow = do
    csConversationId <- field
    csLegacyGroupId <- field
    csKind <- field
    csTitle <- field
    csPlatforms <- field
    csEndpoints <- field
    csMessageCount <- field
    csLastMessageAt <- field
    pure
      ConversationSummary
        { csConversationId,
          csLegacyGroupId,
          csKind,
          csTitle,
          csPlatforms,
          csEndpoints,
          csMessageCount,
          csLastMessageAt
        }

-- | List conversations newest first; aggregate activity once for the whole list.
listConversations ::
  (WithConnection :> es, IOE :> es) =>
  Eff es [ConversationSummary]
listConversations =
  query
    "SELECT c.conversation_id, c.legacy_group_id, c.conversation_kind, \
    \       COALESCE(c.title, e.display_name), e.platforms, \
    \       COALESCE(e.endpoints, 0), COALESCE(m.message_count, 0), m.last_message_at \
    \ FROM conversations c \
    \ LEFT JOIN ( \
    \   SELECT ce.conversation_id, count(*) AS endpoints, \
    \          string_agg(DISTINCT a.platform, ',' ORDER BY a.platform) AS platforms, \
    \          max(ce.display_name) AS display_name \
    \   FROM conversation_endpoints ce \
    \   JOIN platform_accounts a USING (platform_account_id) \
    \   GROUP BY ce.conversation_id \
    \ ) e USING (conversation_id) \
    \ LEFT JOIN ( \
    \   SELECT conversation_id, count(*) AS message_count, max(occurred_at) AS last_message_at \
    \   FROM messages GROUP BY conversation_id \
    \ ) m USING (conversation_id) \
    \ ORDER BY m.last_message_at DESC NULLS LAST, c.conversation_id"
    ()

-- | Persist the roster's room title for admin/history display, writing only changes.
rememberConversationTitle ::
  (WithConnection :> es, IOE :> es) =>
  Int64 ->
  Text ->
  Eff es ()
rememberConversationTitle legacyId title
  | T.null (T.strip title) = pure ()
  | otherwise =
      void $
        execute
          "UPDATE conversations SET title = ? \
          \ WHERE legacy_group_id = ? AND title IS DISTINCT FROM ?"
          (stripped, legacyId, stripped)
  where
    stripped = T.strip title
