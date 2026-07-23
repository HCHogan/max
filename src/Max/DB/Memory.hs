-- |
-- CRUD over the @memories@ table (migration 011).  Two scopes:
-- per-group and per-user, the latter shared across groups.  The
-- interesting policy (caps, permission checks, ephemeral gating)
-- lives in the callers — "Max.Tools.Memory" for the agent side,
-- "Max.Command.Dispatcher" for the human @!memory@ side; this module
-- is just typed SQL.
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
  Eff es [MemoryItem]
listMemories scope sid =
  query
    "SELECT id, scope, scope_id, content, updated_at \
    \  FROM memories WHERE scope = ? AND scope_id = ? \
    \  ORDER BY id"
    (scopeText scope, sid)

countMemories ::
  (WithConnection :> es, IOE :> es) =>
  MemoryScope ->
  Int64 ->
  Eff es Int
countMemories scope sid = do
  rows <-
    query
      "SELECT count(*) FROM memories WHERE scope = ? AND scope_id = ?"
      (scopeText scope, sid)
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
evictOldest ::
  (WithConnection :> es, IOE :> es) =>
  MemoryScope ->
  Int64 ->
  Eff es (Maybe (Int64, Text))
evictOldest scope sid = do
  rows <-
    query
      "DELETE FROM memories WHERE id = \
      \   (SELECT id FROM memories WHERE scope = ? AND scope_id = ? \
      \     ORDER BY updated_at ASC, id ASC LIMIT 1) \
      \ RETURNING id, content"
      (scopeText scope, sid)
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
