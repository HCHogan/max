-- | Storage for Bungie logins and account links. Tokens arrive here already
-- sealed; this module never sees them in clear.
module Max.DB.Bungie
  ( LinkRow (..),
    insertLoginState,
    takeLoginState,
    upsertLink,
    loadLink,
    updateLinkTokens,
    deleteLink,
  )
where

import Control.Monad (void)
import Data.Int (Int64)
import Data.Text (Text)
import Data.Time (UTCTime)
import Database.PostgreSQL.Simple (Only (..))
import Effectful
import Effectful.PostgreSQL (WithConnection, execute, query)
import Max.Platform.Types (PrincipalId (..))

data LinkRow = LinkRow
  { lrBungieMembershipId :: !Int64,
    lrBungieName :: !Text,
    lrMembershipType :: !(Maybe Int),
    lrMembershipId :: !(Maybe Int64),
    lrSealedTokens :: !Text,
    lrAccessExpiresAt :: !UTCTime,
    lrRefreshExpiresAt :: !UTCTime,
    lrLinkedAt :: !UTCTime
  }

-- | Record a pending login and drop expired ones, keeping the table small.
insertLoginState :: (WithConnection :> es, IOE :> es) => Text -> PrincipalId -> Text -> UTCTime -> Eff es ()
insertLoginState stateHash (PrincipalId principal) requester expiresAt = do
  void (execute "DELETE FROM bungie_oauth_states WHERE expires_at < now()" ())
  void $
    execute
      "INSERT INTO bungie_oauth_states (state_sha256, principal_id, requester_name, expires_at) VALUES (?,?,?,?)"
      (stateHash, principal, requester, expiresAt)

-- | Consume a state: the first callback wins, whether or not it succeeds.
takeLoginState :: (WithConnection :> es, IOE :> es) => Text -> Eff es (Maybe (PrincipalId, Text))
takeLoginState stateHash = do
  rows <-
    query
      "DELETE FROM bungie_oauth_states WHERE state_sha256 = ? RETURNING principal_id, requester_name, expires_at > now()"
      (Only stateHash)
  pure $ case rows of
    [(principal, requester, True)] -> Just (PrincipalId principal, requester)
    _ -> Nothing

upsertLink :: (WithConnection :> es, IOE :> es) => PrincipalId -> LinkRow -> Eff es ()
upsertLink (PrincipalId principal) row =
  void $
    execute
      "INSERT INTO bungie_links (principal_id, bungie_membership_id, bungie_name, destiny_membership_type, destiny_membership_id, sealed_tokens, access_expires_at, refresh_expires_at) \
      \VALUES (?,?,?,?,?,?,?,?) \
      \ON CONFLICT (principal_id) DO UPDATE SET bungie_membership_id = EXCLUDED.bungie_membership_id, bungie_name = EXCLUDED.bungie_name, \
      \  destiny_membership_type = EXCLUDED.destiny_membership_type, destiny_membership_id = EXCLUDED.destiny_membership_id, \
      \  sealed_tokens = EXCLUDED.sealed_tokens, access_expires_at = EXCLUDED.access_expires_at, refresh_expires_at = EXCLUDED.refresh_expires_at, \
      \  linked_at = now(), updated_at = now()"
      (principal, row.lrBungieMembershipId, row.lrBungieName, row.lrMembershipType, row.lrMembershipId, row.lrSealedTokens, row.lrAccessExpiresAt, row.lrRefreshExpiresAt)

loadLink :: (WithConnection :> es, IOE :> es) => PrincipalId -> Eff es (Maybe LinkRow)
loadLink (PrincipalId principal) = do
  rows <-
    query
      "SELECT bungie_membership_id, bungie_name, destiny_membership_type, destiny_membership_id, sealed_tokens, access_expires_at, refresh_expires_at, linked_at \
      \  FROM bungie_links WHERE principal_id = ?"
      (Only principal)
  pure $ case rows of
    [(membership, name, kind, ident, sealed, accessExpires, refreshExpires, linkedAt)] ->
      Just (LinkRow membership name kind ident sealed accessExpires refreshExpires linkedAt)
    _ -> Nothing

updateLinkTokens :: (WithConnection :> es, IOE :> es) => PrincipalId -> Text -> UTCTime -> UTCTime -> Eff es ()
updateLinkTokens (PrincipalId principal) sealed accessExpires refreshExpires =
  void $
    execute
      "UPDATE bungie_links SET sealed_tokens = ?, access_expires_at = ?, refresh_expires_at = ?, updated_at = now() WHERE principal_id = ?"
      (sealed, accessExpires, refreshExpires, principal)

deleteLink :: (WithConnection :> es, IOE :> es) => PrincipalId -> Eff es Bool
deleteLink (PrincipalId principal) = (> 0) <$> execute "DELETE FROM bungie_links WHERE principal_id = ?" (Only principal)
