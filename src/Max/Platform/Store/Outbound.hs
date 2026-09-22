{-# LANGUAGE DeriveGeneric #-}

module Max.Platform.Store.Outbound
  ( OutboundDraft (..),
    EnqueuedOutbound (..),
    ReactionDraft (..),
    EnqueuedReaction (..),
    enqueueOutbound,
    enqueueOutboundInTransaction,
    recordInternalMessage,
    enqueueReaction,
  )
where

import Control.Monad (forM_, when)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.Aeson (ToJSON (toJSON), Value, encode)
import Data.ByteString.Base16 qualified as Base16
import Data.ByteString.Lazy qualified as LBS
import Data.Int (Int64)
import Data.Map.Strict qualified as Map
import Data.Maybe (isNothing)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Database.PostgreSQL.Simple.Types (Only (..), PGArray (..))
import Effectful (Eff, IOE, type (:>))
import Effectful.PostgreSQL (WithConnection, execute, query)
import GHC.Generics (Generic)
import Max.DB.Codec (Jsonb (..), exactlyOne)
import Max.DB.PlatformIds (compatibilityId)
import Max.DB.Transaction (withTransaction)
import Max.IR (Body (Body), Phase (Canonical), mentionIdentities)
import Max.IR.Lower
  ( OutboundCaps (reaction),
    outboundCapsFromValue,
  )
import Max.IR.Prompt (promptCanonicalText)
import Max.Monitor.Types (MonitorFireId)
import Max.Platform.Store.Delivery
  ( DeliveryTarget (..),
    deliveryTargets,
  )
import Max.Platform.Store.Endpoint (EndpointRow (..))
import Max.Platform.Store.Identity
  ( ensureIdentityBatch,
    identityPrincipals,
    mentionPrincipalsFor,
  )
import Max.Platform.Store.Relation (resolveReplyProjections)
import Max.Platform.Types
  ( CanonicalMessageId (CanonicalMessageId),
    DeliveryId,
    EndpointId (EndpointId),
    NativeUserId (NativeUserId),
    Platform,
    ReactionAction (..),
    renderPlatform,
  )
import Max.Turn.Types (AgentTurnId (..), TurnOutputLink (..))

data OutboundDraft = OutboundDraft
  { legacyConversationId :: !Int64,
    transcriptKind :: !Text,
    sourceCanonicalMessageId :: !(Maybe Int64),
    -- | Already canonical: the send path resolves every principal the model
    -- addressed to a real account before publishing, so publication never
    -- mints an identity for a number a model invented.
    canonicalBody :: !(Body 'Canonical),
    replyToCanonicalMessageId :: !(Maybe Int64),
    -- | L3 provenance for agent-authored output; absent for commands,
    -- canned monitors, mirroring and other non-turn publication.
    turnOutputLink :: !(Maybe TurnOutputLink),
    -- | Trigger provenance; the unique fire link prevents duplicate publication.
    monitorFireId :: !(Maybe MonitorFireId)
  }
  deriving stock (Eq, Show)

data EnqueuedOutbound = EnqueuedOutbound
  { canonicalMessageId :: !CanonicalMessageId,
    compatibilityMessageId :: !Int64,
    primaryDeliveryId :: !DeliveryId,
    deliveries :: ![DeliveryTarget]
  }
  deriving stock (Eq, Show, Generic)

-- | A non-text action targeting an existing canonical message.  A required
-- platform is used for platform-native vocabularies such as QQ face ids;
-- generic inbound reactions leave it empty and fan out to every capable
-- endpoint holding a native copy of the target.
data ReactionDraft = ReactionDraft
  { legacyConversationId :: !Int64,
    targetCanonicalMessageId :: !Int64,
    reactionKey :: !Text,
    reactionAction :: !ReactionAction,
    requiredPlatform :: !(Maybe Platform)
  }
  deriving stock (Eq, Show, Generic)

data EnqueuedReaction = EnqueuedReaction
  { canonicalMessageId :: !CanonicalMessageId,
    deliveries :: ![DeliveryTarget]
  }
  deriving stock (Eq, Show, Generic)

-- | Commit the canonical message and delivery records before any network send.
-- The process queue owns delivery; a restart does not replay pending rows.
enqueueOutbound ::
  (WithConnection :> es, IOE :> es) =>
  OutboundDraft ->
  Eff es EnqueuedOutbound
enqueueOutbound = withTransaction . enqueueOutboundInTransaction

enqueueOutboundInTransaction ::
  (WithConnection :> es, IOE :> es) =>
  OutboundDraft ->
  Eff es EnqueuedOutbound
enqueueOutboundInTransaction draft = do
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
      \     WHERE source.group_id = ? AND source.canonical_message_id = ?)) \
      \ ORDER BY CASE a.platform WHEN 'qq' THEN 0 ELSE 1 END, e.endpoint_id \
      \ LIMIT 1 FOR UPDATE OF c"
      ( draft.legacyConversationId,
        draft.sourceCanonicalMessageId,
        draft.legacyConversationId,
        draft.sourceCanonicalMessageId
      )
  (primaryEndpoint, conversation, account, platformName, accountNative, legacyGroup) <-
    case primaryRows :: [(Int64, Int64, Int64, Text, Text, Maybe Int64)] of
      [row] -> pure row
      _ -> error "enqueueOutbound: conversation has no enabled endpoint"
  let endpointRow =
        EndpointRow
          { erEndpointId = primaryEndpoint,
            erConversationId = conversation,
            erPlatformAccountId = account,
            erPlatform = platformName,
            erNativeAccountId = accountNative,
            erLegacyGroupId = legacyGroup
          }
  forM_ draft.monitorFireId $ \fireId -> do
    scoped <-
      query
        "SELECT 1 FROM monitor_fires f JOIN monitors m USING (monitor_id) \
        \ WHERE f.fire_id=? AND m.conversation_id=? AND m.status IN ('armed','fired') \
        \   AND f.admission_state='dispatched' AND f.finished_at IS NULL AND f.cancelled_at IS NULL \
        \ FOR UPDATE OF m"
        (fireId, conversation)
    case scoped :: [Only Int] of
      [_] -> pure ()
      _ -> error "enqueueOutbound: monitor fire outside conversation"
  -- An outbound body already names identities: the send path resolved every
  -- principal the model addressed against a real account before publishing.
  -- The only identity this transaction has to ensure is the bot's own.
  identities <-
    ensureIdentityBatch endpointRow (Map.singleton (NativeUserId accountNative) (Just "max"))
  (_, principal) <- case Map.lookup (NativeUserId accountNative) identities of
    Just found -> pure found
    Nothing -> error "enqueueOutbound: bot identity missing from batch"
  mentionPrincipals <- mentionPrincipalsFor (mentionIdentities draft.canonicalBody)
  let renderedProjection =
        promptCanonicalText (Map.union (identityPrincipals identities) mentionPrincipals) draft.canonicalBody
  canonicalRows <- query "SELECT nextval('canonical_message_id_seq')" ()
  let canonical = exactlyOne "enqueueOutbound canonical id" (canonicalRows :: [Only Int64])
  compatibilityRows <- query "SELECT -nextval('synthetic_message_id_seq')" ()
  let compatibilityMessage = exactlyOne "enqueueOutbound compatibility id" (compatibilityRows :: [Only Int64])
  compatibilitySelf <- compatibilityId platformName "user" accountNative
  replyTarget <- resolveReplyProjections conversation draft.replyToCanonicalMessageId
  let replyCanonical = fst <$> replyTarget
      replyCompatibility = snd <$> replyTarget
      (agentTurnId, turnChunkIndex) = turnOutputColumns draft.turnOutputLink
  inserted <-
    execute
      "INSERT INTO messages \
      \ (canonical_message_id, message_id, group_id, user_id, self_id, segments, canonical_content, \
      \  rendered_text, raw_message, sender_nickname, reply_to_message_id, reply_to_canonical_message_id, \
      \  kind, conversation_id, author_principal_id, origin_endpoint_id, source_native_event_id, \
      \  agent_turn_id, turn_chunk_index, monitor_fire_id, occurred_at, message_origin, source_platform) \
      \ VALUES (?, ?, ?, ?, ?, ?, ?, ?, '', 'max', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, now(), 'outbound', ?)"
      ( canonical,
        compatibilityMessage,
        draft.legacyConversationId,
        compatibilitySelf,
        compatibilitySelf,
        Jsonb (toJSON ([] :: [Value])),
        Jsonb (toJSON draft.canonicalBody),
        renderedProjection,
        replyCompatibility,
        replyCanonical,
        draft.transcriptKind,
        conversation,
        principal,
        primaryEndpoint,
        "max:" <> T.pack (show canonical),
        agentTurnId,
        turnChunkIndex,
        draft.monitorFireId,
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
      "INSERT INTO message_deliveries \
      \ (canonical_message_id, endpoint_id, status, idempotency_key) \
      \ SELECT ?, e.endpoint_id, 'pending', 'out:' || ?::text || ':' || e.endpoint_id::text \
      \ FROM conversation_endpoints e \
      \ JOIN platform_accounts a USING (platform_account_id) \
      \ WHERE e.conversation_id = ? AND e.enabled AND a.enabled \
      \   AND (?::boolean OR e.endpoint_id = ?) \
      \ ON CONFLICT (canonical_message_id, endpoint_id) DO NOTHING"
      (canonical, canonical, conversation, isNothing draft.sourceCanonicalMessageId, primaryEndpoint)
  targets <- deliveryTargets (CanonicalMessageId canonical)
  let primary = case [target.deliveryId | target <- targets, target.endpointId == EndpointId primaryEndpoint] of
        [identifier] -> identifier
        _ -> error "enqueueOutbound: expected one primary copy"
  pure
    EnqueuedOutbound
      { canonicalMessageId = CanonicalMessageId canonical,
        compatibilityMessageId = compatibilityMessage,
        primaryDeliveryId = primary,
        deliveries = targets
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
      \     WHERE source.group_id = ? AND source.canonical_message_id = ?)) \
      \ ORDER BY CASE a.platform WHEN 'qq' THEN 0 ELSE 1 END, e.endpoint_id \
      \ LIMIT 1 FOR UPDATE OF c"
      ( draft.legacyConversationId,
        draft.sourceCanonicalMessageId,
        draft.legacyConversationId,
        draft.sourceCanonicalMessageId
      )
  (primaryEndpoint, conversation, account, platformName, accountNative) <-
    case primaryRows :: [(Int64, Int64, Int64, Text, Text)] of
      [row] -> pure row
      _ -> error "recordInternalMessage: conversation has no enabled endpoint"
  let endpointRow =
        EndpointRow
          { erEndpointId = primaryEndpoint,
            erConversationId = conversation,
            erPlatformAccountId = account,
            erPlatform = platformName,
            erNativeAccountId = accountNative,
            erLegacyGroupId = Just draft.legacyConversationId
          }
  identities <-
    ensureIdentityBatch endpointRow (Map.singleton (NativeUserId accountNative) (Just "max"))
  (_, principal) <- case Map.lookup (NativeUserId accountNative) identities of
    Just found -> pure found
    Nothing -> error "recordInternalMessage: bot identity missing from batch"
  mentionPrincipals <- mentionPrincipalsFor (mentionIdentities draft.canonicalBody)
  let renderedProjection =
        promptCanonicalText (Map.union (identityPrincipals identities) mentionPrincipals) draft.canonicalBody
      contentHash = TE.decodeUtf8 (Base16.encode (SHA256.hash (LBS.toStrict (encode draft.canonicalBody))))
      sourceKey =
        "max:internal:"
          <> T.pack (show conversation)
          <> ":"
          <> maybe "none" (T.pack . show) draft.sourceCanonicalMessageId
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
      canonicalRows <- query "SELECT nextval('canonical_message_id_seq')" ()
      compatibilityRows <- query "SELECT -nextval('synthetic_message_id_seq')" ()
      let canonical = exactlyOne "recordInternalMessage canonical id" (canonicalRows :: [Only Int64])
          compatibilityMessage = exactlyOne "recordInternalMessage compatibility id" (compatibilityRows :: [Only Int64])
      compatibilitySelf <- compatibilityId platformName "user" accountNative
      replyTarget <- resolveReplyProjections conversation draft.replyToCanonicalMessageId
      let replyCanonical = fst <$> replyTarget
          replyCompatibility = snd <$> replyTarget
          (agentTurnId, turnChunkIndex) = turnOutputColumns draft.turnOutputLink
      inserted <-
        execute
          "INSERT INTO messages \
          \ (canonical_message_id, message_id, group_id, user_id, self_id, segments, canonical_content, \
          \  rendered_text, raw_message, sender_nickname, reply_to_message_id, reply_to_canonical_message_id, \
          \  kind, conversation_id, author_principal_id, origin_endpoint_id, source_native_event_id, \
          \  agent_turn_id, turn_chunk_index, occurred_at, message_origin, source_platform) \
          \ VALUES (?, ?, ?, ?, ?, '[]'::jsonb, ?, ?, '', 'max', ?, ?, ?, ?, ?, ?, ?, ?, ?, now(), 'internal', ?)"
          ( canonical,
            compatibilityMessage,
            draft.legacyConversationId,
            compatibilitySelf,
            compatibilitySelf,
            Jsonb (toJSON draft.canonicalBody),
            renderedProjection,
            replyCompatibility,
            replyCanonical,
            draft.transcriptKind,
            conversation,
            principal,
            primaryEndpoint,
            sourceKey,
            agentTurnId,
            turnChunkIndex,
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
      pure (CanonicalMessageId canonical)
    _ -> error "recordInternalMessage: duplicate source key invariant violated"

turnOutputColumns :: Maybe TurnOutputLink -> (Maybe AgentTurnId, Maybe Int)
turnOutputColumns = \case
  Nothing -> (Nothing, Nothing)
  Just link -> (Just link.tolTurnId, Just link.tolChunkIndex)

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
      \ WHERE c.legacy_group_id = ? AND m.canonical_message_id = ?"
      (draft.legacyConversationId, draft.targetCanonicalMessageId)
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
          "SELECT m.canonical_message_id FROM messages m \
          \ WHERE m.conversation_id = ? AND m.message_origin = 'internal' \
          \   AND m.event_kind = 'reaction' AND m.source_native_event_id = ?"
          (conversation, sourceKey)
      case existing :: [Only Int64] of
        [Only canonical] ->
          pure (Just EnqueuedReaction {canonicalMessageId = CanonicalMessageId canonical, deliveries = []})
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
                  { erEndpointId = originEndpoint,
                    erConversationId = conversation,
                    erPlatformAccountId = account,
                    erPlatform = platformName,
                    erNativeAccountId = accountNative,
                    erLegacyGroupId = legacyGroup
                  }
          identities <- ensureIdentityBatch endpointRow (Map.singleton (NativeUserId accountNative) (Just "max"))
          principal <- case Map.elems identities of
            [(_, identifier)] -> pure identifier
            _ -> error "enqueueReaction: missing self identity"
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
              "INSERT INTO message_deliveries \
              \ (canonical_message_id, endpoint_id, status, idempotency_key) \
              \ SELECT ?, endpoint_id, 'pending', \
              \        'reaction:' || ?::text || ':' || endpoint_id::text \
              \ FROM conversation_endpoints WHERE endpoint_id = ANY(?) \
              \ ON CONFLICT (canonical_message_id, endpoint_id) DO NOTHING"
              (canonical, canonical, endpointIds)
          targets <- deliveryTargets (CanonicalMessageId canonical)
          pure
            ( Just
                EnqueuedReaction
                  { canonicalMessageId = CanonicalMessageId canonical,
                    deliveries = targets
                  }
            )
