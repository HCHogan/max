-- | Lossless read-side enrichment for the authenticated admin surface.
-- Unlike endpoint lowering, hydration never drops or folds a node.
module Max.IR.Hydrate
  ( hydrate,
    hydratedBodyValue,
  )
where

import Data.Aeson (Value, object, (.=))
import Data.Int (Int64)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Effectful
import Effectful.PostgreSQL (WithConnection, query)
import Max.IR
import Max.Platform.Types
import Database.PostgreSQL.Simple.Types (Only (..))

hydrate ::
  (WithConnection :> es, IOE :> es) =>
  CanonicalMessageId ->
  Body 'Canonical ->
  Eff es (Body 'Hydrated)
hydrate canonical body = Body <$> traverse hydrateNode body.nodes
  where
    hydrateNode = \case
      NText text -> pure (NText text)
      NMention target display -> NMention <$> hydrateMention target <*> pure display
      NEmote emote -> pure (NEmote emote)
      NMedia source meta -> pure (NMedia (mediaView source meta) meta)
      NCard card -> pure (NCard card)
      NForward _ -> NForward <$> hydrateForward canonical
      NUnsupported unsupported -> pure (NUnsupported unsupported)

hydrateMention ::
  (WithConnection :> es, IOE :> es) =>
  MentionTarget ->
  Eff es HydratedMention
hydrateMention MentionAll =
  pure
    HydratedMention
      { principal = Nothing,
        displayName = Nothing,
        identities = [],
        allMembers = True
      }
hydrateMention (MentionIdentity (PrincipalIdentityId identity)) = do
  principalRows <-
    query
      "SELECT p.principal_id, p.display_name \
      \ FROM principal_identities identity \
      \ JOIN principals p USING (principal_id) \
      \ WHERE identity.principal_identity_id = ?"
      (Only identity)
  (principalId, display) <- case principalRows :: [(Int64, Maybe Text)] of
    [row] -> pure row
    _ -> error "hydrateMention: canonical identity is missing"
  identityRows <-
    query
      "SELECT account.platform, identity.native_user_id \
      \ FROM principal_identities identity \
      \ JOIN platform_accounts account USING (platform_account_id) \
      \ WHERE identity.principal_id = ? \
      \ ORDER BY account.platform, identity.principal_identity_id"
      (Only principalId)
  pure
    HydratedMention
      { principal = Just (PrincipalId principalId),
        displayName = display,
        identities = [(parsePlatform platform, NativeUserId native) | (platform, native) <- identityRows],
        allMembers = False
      }

mediaView :: Maybe MediaRef -> MediaMeta -> MediaView
mediaView source meta =
  MediaView
    { url = maybe "" adminMediaUrl source,
      thumbnail = case (source, meta.kind) of
        (Just ref, MImage) -> Just (adminMediaUrl ref)
        (Just ref, MSticker) -> Just (adminMediaUrl ref)
        _ -> Nothing,
      ref = source
    }

adminMediaUrl :: MediaRef -> Text
adminMediaUrl ref = case mediaRefBlobSha ref of
  Just sha -> "/api/blobs/" <> sha
  Nothing -> fromMaybe "" (mediaRefRemoteUrl ref)

hydrateForward ::
  (WithConnection :> es, IOE :> es) =>
  CanonicalMessageId ->
  Eff es HydratedForward
hydrateForward (CanonicalMessageId canonical) = do
  rows <-
    query
      "SELECT relation.canonical_message_id \
      \ FROM message_relations relation \
      \ WHERE relation.relation_kind = 'contained_in' \
      \   AND relation.target_canonical_message_id = ? \
      \ ORDER BY relation.relation_position, relation.relation_id"
      (Only canonical)
  pure (HydratedForward (CanonicalMessageId . fromOnly <$> rows))

-- | The admin emitter is intentionally separate from the stored codec: it
-- exposes hydrated decorations and can evolve without creating another
-- durable message representation.
hydratedBodyValue :: Body 'Hydrated -> Value
hydratedBodyValue body = object ["nodes" .= (nodeValue <$> body.nodes)]
  where
    nodeValue = \case
      NText text -> object ["type" .= ("text" :: Text), "text" .= text]
      NMention mention display ->
        object
          [ "type" .= ("mention" :: Text),
            "display" .= display,
            "principal_id" .= mention.principal,
            "principal_display" .= mention.displayName,
            "all" .= mention.allMembers,
            "identities"
              .= [ object ["platform" .= renderPlatform platform, "native_user_id" .= native]
                 | (platform, NativeUserId native) <- mention.identities
                 ]
          ]
      NEmote emote ->
        object
          [ "type" .= ("emote" :: Text),
            "platform" .= renderPlatform emote.origin,
            "native_id" .= emote.nativeId,
            "name" .= emote.name,
            "raw" .= emote.raw
          ]
      NMedia view meta ->
        object
          [ "type" .= ("media" :: Text),
            "kind" .= mediaKindText meta.kind,
            "url" .= view.url,
            "thumbnail" .= view.thumbnail,
            "canonical_ref" .= (renderMediaRef <$> view.ref),
            "mime" .= meta.mime,
            "size" .= meta.sizeBytes,
            "name" .= meta.name,
            "description" .= meta.description,
            "raw" .= meta.raw
          ]
      NCard card ->
        object
          [ "type" .= ("card" :: Text),
            "title" .= card.title,
            "subtitle" .= card.subtitle,
            "url" .= card.url,
            "tag" .= card.tag,
            "preview" .= (adminMediaUrl <$> card.preview),
            "raw" .= card.raw
          ]
      NForward forward ->
        object ["type" .= ("forward" :: Text), "children" .= forward.children]
      NUnsupported unsupported ->
        object
          [ "type" .= ("unsupported" :: Text),
            "source" .= unsupported.source,
            "description" .= unsupported.description,
            "raw" .= unsupported.raw
          ]
