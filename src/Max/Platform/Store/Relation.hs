module Max.Platform.Store.Relation
  ( compatibilityMessageIdForCanonical,
    nativeEventIdForCanonical,
    latestNativeEventId,
    nativeEventWasDeliveredTo,
    resolveReplyProjections,
    resolveReply,
    insertRelation,
    resolveNativeTarget,
  )
where

import Data.Int (Int64)
import Data.List (find)
import Data.Maybe (listToMaybe)
import Data.Text (Text)
import Database.PostgreSQL.Simple.Types (Only (..))
import Effectful (Eff, IOE, type (:>))
import Effectful.PostgreSQL (WithConnection, execute, query)
import Max.DB.Codec (exactlyOne)
import Max.Platform.Types
  ( CanonicalMessageId (CanonicalMessageId),
    EndpointId (EndpointId),
    MessageRelation (..),
    NativeEventId (NativeEventId),
    ReactionAction (ReactionAdd),
  )

compatibilityMessageIdForCanonical ::
  (WithConnection :> es, IOE :> es) =>
  CanonicalMessageId ->
  Eff es Int64
compatibilityMessageIdForCanonical (CanonicalMessageId canonical) = do
  rows <- query "SELECT message_id FROM messages WHERE canonical_message_id = ?" (Only canonical)
  pure (exactlyOne "compatibilityMessageIdForCanonical" rows)

-- | Resolve the ingestion-native ID for a relation target. Storing a canonical
-- ID in the native column would leave the relation unresolved.
nativeEventIdForCanonical ::
  (WithConnection :> es, IOE :> es) =>
  CanonicalMessageId ->
  Eff es NativeEventId
nativeEventIdForCanonical (CanonicalMessageId canonical) = do
  rows <-
    query
      "SELECT source_native_event_id FROM messages WHERE canonical_message_id = ?"
      (Only canonical)
  pure (NativeEventId (exactlyOne "nativeEventIdForCanonical" rows))

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

-- | Whether a native id names a copy Max delivered onto this endpoint, rather
-- than an event that originated there. Some transports expose a rolling
-- predecessor pointer even on ordinary top-level messages; adapters can use
-- this narrower fact to recover reply UI provenance only when the predecessor
-- is one of Max's known outbound copies.
nativeEventWasDeliveredTo ::
  (WithConnection :> es, IOE :> es) =>
  EndpointId ->
  NativeEventId ->
  Eff es Bool
nativeEventWasDeliveredTo (EndpointId endpoint) (NativeEventId nativeEvent) = do
  rows <-
    query
      "SELECT EXISTS ( \
      \ SELECT 1 FROM message_deliveries \
      \ WHERE endpoint_id = ? AND native_event_id = ? \
      \   AND idempotency_key NOT LIKE 'source:%')"
      (endpoint, nativeEvent)
  case rows :: [Only Bool] of
    [Only delivered] -> pure delivered
    _ -> error "nativeEventWasDeliveredTo: existence query did not return one row"

-- | Resolve canonical and compatibility reply IDs within one conversation.
resolveReplyProjections ::
  (WithConnection :> es, IOE :> es) =>
  Int64 -> -- conversation id
  Maybe Int64 -> -- canonical message id
  Eff es (Maybe (Int64, Int64))
resolveReplyProjections _ Nothing = pure Nothing
resolveReplyProjections conversation (Just target) = do
  rows <-
    query
      "SELECT canonical_message_id, message_id FROM messages \
      \ WHERE conversation_id = ? AND canonical_message_id = ?"
      (conversation, target)
  pure (listToMaybe (rows :: [(Int64, Int64)]))

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
        \ FROM message_delivery_copies d \
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
      \ FROM message_delivery_copies \
      \ WHERE endpoint_id = ? AND native_event_id = ? \
      \ ) target \
      \ ORDER BY target.source_rank, target.copied_at DESC, target.copy_id DESC \
      \ LIMIT 1"
      (endpoint, target, endpoint, target)
  pure (fromOnly <$> listToMaybe rows)
