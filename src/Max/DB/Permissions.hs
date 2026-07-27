-- |
-- Typed SQL over the @permissions@ table (migration 024): explicit
-- per-user capability grants/denies that sit between the config-level
-- owner list and the NapCat-role tier — see "Max.Command.Permission"
-- for the resolution order.  A group-scoped row beats a global row.
module Max.DB.Permissions
  ( lookupGrant,
    insertGrant,
    deleteGrant,
    listGrantsFor,
    GrantRow (..),
    listGrants,
    deleteGrantById,
  )
where

import Data.Int (Int64)
import Data.Text (Text)
import Data.Time (UTCTime)
import Database.PostgreSQL.Simple (Only (..))
import Effectful
import Effectful.PostgreSQL (WithConnection, execute, query)

-- | The effective explicit grant for (user, capability) in a group:
-- @Just True@ = allowed, @Just False@ = explicitly denied, @Nothing@
-- = no explicit row (fall through to the role tier).  A row scoped to
-- this group shadows a global (NULL-scope) row.
lookupGrant ::
  (WithConnection :> es, IOE :> es) =>
  Int64 -> -- user id
  Text -> -- capability
  Int64 -> -- group id
  Eff es (Maybe Bool)
lookupGrant uid cap gid = do
  rows <-
    query
      "SELECT deny FROM permissions \
      \ WHERE user_id = ? AND capability = ? \
      \   AND (scope_group_id = ? OR scope_group_id IS NULL) \
      \ ORDER BY scope_group_id NULLS LAST \
      \ LIMIT 1"
      (uid, cap, gid)
  pure $ case rows of
    (Only deny : _) -> Just (not deny)
    [] -> Nothing

-- | Upsert one grant/deny row.  Returns the row id.
insertGrant ::
  (WithConnection :> es, IOE :> es) =>
  Int64 -> -- user id
  Text -> -- capability
  Maybe Int64 -> -- scope group (Nothing = global)
  Bool -> -- deny?
  Int64 -> -- granted_by
  Eff es ()
insertGrant uid cap scope deny by = do
  _ <-
    execute
      "INSERT INTO permissions (user_id, capability, scope_group_id, deny, granted_by) \
      \ VALUES (?,?,?,?,?) \
      \ ON CONFLICT (user_id, capability, scope_group_id) \
      \ DO UPDATE SET deny = EXCLUDED.deny, granted_by = EXCLUDED.granted_by, granted_at = now()"
      (uid, cap, scope, deny, by)
  pure ()

-- | Drop a grant row; 'False' when nothing matched.
deleteGrant ::
  (WithConnection :> es, IOE :> es) =>
  Int64 ->
  Text ->
  Maybe Int64 ->
  Eff es Bool
deleteGrant uid cap scope = do
  n <-
    execute
      "DELETE FROM permissions WHERE user_id = ? AND capability = ? \
      \ AND scope_group_id IS NOT DISTINCT FROM ?"
      (uid, cap, scope)
  pure (n > 0)

-- | One full permissions row, id and audit trail included — the
-- admin surface's view, where rows are deleted by id rather than by
-- (user, capability, scope) triple.
data GrantRow = GrantRow
  { grId :: !Int64,
    grUser :: !Int64,
    grCapability :: !Text,
    grScope :: !(Maybe Int64),
    grDeny :: !Bool,
    grGrantedBy :: !Int64,
    grGrantedAt :: !UTCTime
  }
  deriving stock (Show, Eq)

-- | Every explicit grant/deny row.  Small by construction (one row
-- per deliberate !grant), so no pagination.
listGrants :: (WithConnection :> es, IOE :> es) => Eff es [GrantRow]
listGrants = do
  rows <-
    query
      "SELECT id, user_id, capability, scope_group_id, deny, granted_by, granted_at \
      \  FROM permissions ORDER BY user_id, capability, scope_group_id NULLS FIRST"
      ()
  pure [GrantRow i u c s d by at | (i, u, c, s, d, by, at) <- rows]

-- | Drop one row by primary key; 'False' when the id is unknown.
deleteGrantById :: (WithConnection :> es, IOE :> es) => Int64 -> Eff es Bool
deleteGrantById rid = do
  n <- execute "DELETE FROM permissions WHERE id = ?" (Only rid)
  pure (n > 0)

-- | All explicit rows for a user (for @!perms@): (capability, scope, deny).
listGrantsFor ::
  (WithConnection :> es, IOE :> es) =>
  Int64 ->
  Eff es [(Text, Maybe Int64, Bool)]
listGrantsFor uid =
  query
    "SELECT capability, scope_group_id, deny FROM permissions \
    \ WHERE user_id = ? ORDER BY capability, scope_group_id NULLS FIRST"
    [uid]
