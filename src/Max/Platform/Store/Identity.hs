module Max.Platform.Store.Identity
  ( ensureIdentityBatch,
    identityPrincipals,
    batchIdentities,
    mentionPrincipalsFor,
    ensureEndpointPrincipals,
    resolveMentionIdentities,
    bodyMentionDisplays,
    resolveBodyMentions,
  )
where

import Control.Applicative ((<|>))
import Control.Monad (unless, void)
import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Database.PostgreSQL.Simple.Types (Only (..), PGArray (..))
import Effectful (Eff, IOE, type (:>))
import Effectful.PostgreSQL (WithConnection, execute, query)
import Max.DB.Codec (exactlyOne)
import Max.DB.Transaction (withTransaction)
import Max.IR
  ( Body (nodes),
    MentionTarget (MentionIdentity),
    Node (NMention),
    Phase (Canonical, Ingest),
    resolveIngest,
  )
import Max.Platform.Store.Endpoint
  ( EndpointRow (..),
    fetchEndpoint,
  )
import Max.Platform.Types
  ( EndpointId,
    NativeUserId (NativeUserId),
    PrincipalId (..),
    PrincipalIdentityId (..),
  )

-- | Ensure principal identities for a batch of native users in ascending
-- native-id order.  Every caller that takes identity row locks must go
-- through one sorted batch per transaction, so concurrent transactions
-- cannot acquire FOR UPDATE locks in opposite orders.
ensureIdentityBatch ::
  (WithConnection :> es, IOE :> es) =>
  EndpointRow ->
  Map NativeUserId (Maybe Text) ->
  Eff es (Map NativeUserId (Int64, Int64))
ensureIdentityBatch endpoint natives = do
  identities <- Map.traverseWithKey (ensurePrincipalIdentity endpoint) natives
  unless (Map.null identities) $
    void $
      execute
        "INSERT INTO endpoint_known_identities(endpoint_id,principal_identity_id) SELECT ?,unnest(?::bigint[]) ON CONFLICT DO NOTHING"
        (endpoint.erEndpointId, PGArray (map fst (Map.elems identities)))
  pure identities

-- | Reuse resolved identities for prompt rendering. Render the canonical body
-- after mention resolution so stored text agrees with verification/reprojection.
identityPrincipals :: Map NativeUserId (Int64, Int64) -> Map PrincipalIdentityId PrincipalId
identityPrincipals identities =
  Map.fromList
    [ (PrincipalIdentityId identity, PrincipalId principal)
    | (identity, principal) <- Map.elems identities
    ]

-- | Just the identity ids, for the paths that resolve mention nodes.
batchIdentities :: Map NativeUserId (Int64, Int64) -> Map NativeUserId Int64
batchIdentities = Map.map fst

-- | The identity → principal join every model-facing projection needs
-- (ADR 004).  Always defined: an identity belongs to exactly one principal,
-- and the column is @NOT NULL@.
mentionPrincipalsFor ::
  (WithConnection :> es, IOE :> es) =>
  [PrincipalIdentityId] ->
  Eff es (Map PrincipalIdentityId PrincipalId)
mentionPrincipalsFor [] = pure Map.empty
mentionPrincipalsFor identities = do
  rows <-
    query
      "SELECT principal_identity_id, principal_id FROM principal_identities \
      \ WHERE principal_identity_id = ANY(?)"
      (Only (PGArray (map unPrincipalIdentityId identities)))
  pure . Map.fromList $
    [ (PrincipalIdentityId identity, PrincipalId principal)
    | (identity, principal) <- (rows :: [(Int64, Int64)])
    ]

-- | Resolve principals for interactions without a message, such as pokes.
-- Create identities only for accounts proven by this endpoint.
ensureEndpointPrincipals ::
  (WithConnection :> es, IOE :> es) =>
  EndpointId ->
  Map NativeUserId (Maybe Text) ->
  Eff es (Map NativeUserId PrincipalId)
ensureEndpointPrincipals endpointId natives
  | Map.null natives = pure Map.empty
  | otherwise = withTransaction $ do
      endpoint <- fetchEndpoint endpointId
      Map.map (PrincipalId . snd) <$> ensureIdentityBatch endpoint natives

-- | Resolve principals only through this conversation's endpoint accounts.
-- Prefer its primary delivery account, then other available accounts. Unresolved
-- principals cannot create identities or address people outside the conversation.
resolveMentionIdentities ::
  (WithConnection :> es, IOE :> es) =>
  Int64 -> -- legacy conversation id
  [PrincipalId] ->
  Eff es (Map PrincipalId PrincipalIdentityId)
resolveMentionIdentities _ [] = pure Map.empty
resolveMentionIdentities conversation principals = do
  rows <-
    query
      "SELECT DISTINCT ON (pi.principal_id) pi.principal_id, pi.principal_identity_id \
      \ FROM conversations c \
      \ JOIN conversation_endpoints e ON e.conversation_id = c.conversation_id AND e.enabled \
      \ JOIN platform_accounts a ON a.platform_account_id = e.platform_account_id AND a.enabled \
      \ JOIN endpoint_known_identities known ON known.endpoint_id=e.endpoint_id \
      \ JOIN principal_identities pi ON pi.principal_identity_id=known.principal_identity_id AND pi.platform_account_id=a.platform_account_id \
      \ WHERE c.legacy_group_id = ? AND pi.principal_id = ANY(?) \
      \ ORDER BY pi.principal_id, \
      \          CASE a.platform WHEN 'qq' THEN 0 ELSE 1 END, e.endpoint_id, \
      \          pi.updated_at DESC, pi.principal_identity_id DESC"
      (conversation, PGArray (map unPrincipalId principals))
  pure . Map.fromList $
    [ (PrincipalId principal, PrincipalIdentityId identity)
    | (principal, identity) <- (rows :: [(Int64, Int64)])
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

ensurePrincipalIdentity ::
  (WithConnection :> es, IOE :> es) =>
  EndpointRow ->
  NativeUserId ->
  Maybe Text ->
  Eff es (Int64, Int64)
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
        [Only identity] -> pure (identity, principal)
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
          pure (identity, principal)
        _ -> pure (identity, principal)
