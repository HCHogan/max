-- |
-- CRUD over the @memories@ table (migration 011).  Two scopes,
-- per-group and per-user, and __neither leaves the conversation it was
-- learned in__.  The interesting policy (caps, permission checks,
-- ephemeral gating) lives in the callers — "Max.Tools.Memory" for the
-- agent side, "Max.Command.Dispatcher" for the human @!memory@ side;
-- this module is just typed SQL.
--
-- __Why user memories are group-scoped.__  They used to be one row per
-- person, injected wherever that person turned up.  But the extractor
-- reads group context, so a fact from group A's chatter would land in
-- the speaker's user scope and then ride along into group B — the bot
-- repeating things nobody there had said.  @source_group_id@ has
-- recorded the origin since migration 011, so scoping reads by it costs
-- no migration and makes both scopes behave the same way.
--
-- Every scope-partitioned query therefore takes the current group, and
-- carries @(scope = 'group' OR source_group_id = ?)@: a no-op for group
-- rows (already partitioned by @scope_id@), the whole point for user
-- rows.
module Max.DB.Memory
  ( MemoryScope (..),
    MemoryItem (..),
    scopeText,
    parseScope,
    listMemories,
    countMemories,
    insertMemory,
    updateMemory,
    deleteMemory,
    evictOldest,
    fetchMemory,
  )
where

import Data.Int (Int64)
import Data.Text (Text)
import Data.Time (UTCTime)
import Database.PostgreSQL.Simple (Only (..))
import Database.PostgreSQL.Simple.FromRow (FromRow, field, fromRow)
import Effectful
import Effectful.PostgreSQL (WithConnection, execute, query)

data MemoryScope = ScopeGroup | ScopeUser
  deriving stock (Show, Eq)

scopeText :: MemoryScope -> Text
scopeText ScopeGroup = "group"
scopeText ScopeUser = "user"

parseScope :: Text -> Maybe MemoryScope
parseScope "group" = Just ScopeGroup
parseScope "user" = Just ScopeUser
parseScope _ = Nothing

-- | One remembered fact.  Scope/scope_id are carried so a fetched row
-- can be permission-checked without a second query.
data MemoryItem = MemoryItem
  { memId :: !Int64,
    memScope :: !Text,
    memScopeId :: !Int64,
    memContent :: !Text,
    memUpdatedAt :: !UTCTime
  }
  deriving stock (Show, Eq)

instance FromRow MemoryItem where
  fromRow = MemoryItem <$> field <*> field <*> field <*> field <*> field

-- | All memories of one scope, oldest first — reads as accumulated
-- knowledge, and ids stay stable across renders.
listMemories ::
  (WithConnection :> es, IOE :> es) =>
  MemoryScope ->
  Int64 ->
  -- | Current group.  Confines user-scope rows to where they were
  -- learned; ignored for group scope.
  Int64 ->
  Eff es [MemoryItem]
listMemories scope sid gid =
  query
    "SELECT id, scope, scope_id, content, updated_at \
    \  FROM memories \
    \  WHERE scope = ? AND scope_id = ? \
    \    AND (scope = 'group' OR source_group_id = ?) \
    \  ORDER BY id"
    (scopeText scope, sid, gid)

-- | Counts what 'listMemories' would return, so the per-scope cap is
-- measured over the same rows the prompt actually sees.
countMemories ::
  (WithConnection :> es, IOE :> es) =>
  MemoryScope ->
  Int64 ->
  Int64 ->
  Eff es Int
countMemories scope sid gid = do
  rows <-
    query
      "SELECT count(*) FROM memories \
      \ WHERE scope = ? AND scope_id = ? \
      \   AND (scope = 'group' OR source_group_id = ?)"
      (scopeText scope, sid, gid)
  pure $ case rows of
    [Only (n :: Int64)] -> fromIntegral n
    _ -> 0

-- | Insert and return the new id.
insertMemory ::
  (WithConnection :> es, IOE :> es) =>
  MemoryScope ->
  Int64 ->
  Text ->
  Maybe Int64 -> -- source group (where it was learned), for user scope
  Eff es Int64
insertMemory scope sid content srcGid = do
  rows <-
    query
      "INSERT INTO memories (scope, scope_id, content, source_group_id) \
      \  VALUES (?, ?, ?, ?) RETURNING id"
      (scopeText scope, sid, content, srcGid)
  pure $ case rows of
    [Only n] -> n
    _ -> 0 -- unreachable: RETURNING on a successful insert yields one row

-- | Returns 'False' when the id doesn't exist.
updateMemory ::
  (WithConnection :> es, IOE :> es) =>
  Int64 ->
  Text ->
  Eff es Bool
updateMemory mid content = do
  n <-
    execute
      "UPDATE memories SET content = ?, updated_at = now() WHERE id = ?"
      (content, mid)
  pure (n > 0)

-- | Returns 'False' when the id doesn't exist.
deleteMemory :: (WithConnection :> es, IOE :> es) => Int64 -> Eff es Bool
deleteMemory mid = do
  n <- execute "DELETE FROM memories WHERE id = ?" (Only mid)
  pure (n > 0)

-- | Drop the scope's least-recently-touched memory (oldest
-- @updated_at@) and return its id and content — so the caller can
-- log what got forgotten.  'Nothing' when the scope is empty.
-- Evicts from the same slice the cap counts, so making room in one
-- group can never silently forget what another group taught the bot
-- about the same person.
evictOldest ::
  (WithConnection :> es, IOE :> es) =>
  MemoryScope ->
  Int64 ->
  Int64 ->
  Eff es (Maybe (Int64, Text))
evictOldest scope sid gid = do
  rows <-
    query
      "DELETE FROM memories WHERE id = \
      \   (SELECT id FROM memories \
      \     WHERE scope = ? AND scope_id = ? \
      \       AND (scope = 'group' OR source_group_id = ?) \
      \     ORDER BY updated_at ASC, id ASC LIMIT 1) \
      \ RETURNING id, content"
      (scopeText scope, sid, gid)
  pure $ case rows of
    (r : _) -> Just r
    [] -> Nothing

fetchMemory :: (WithConnection :> es, IOE :> es) => Int64 -> Eff es (Maybe MemoryItem)
fetchMemory mid = do
  rows <-
    query
      "SELECT id, scope, scope_id, content, updated_at \
      \  FROM memories WHERE id = ?"
      (Only mid)
  pure $ case rows of
    (m : _) -> Just m
    [] -> Nothing
