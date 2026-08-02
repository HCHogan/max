-- |
-- CRUD over the @memories@ table (migration 011).  Two scopes,
-- per-group and per-user, and __neither leaves the conversation it was
-- learned in__. This module owns the namespace predicates so tools,
-- extractors, commands, and prompt assembly cannot accidentally turn a bare
-- memory id into cross-conversation authority. Higher-level policy such as
-- caps and extraction thresholds remains in the callers.
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
    MemoryNamespace,
    MemoryItem (..),
    scopeText,
    parseScope,
    groupMemoryNamespace,
    userMemoryNamespace,
    memoryNamespace,
    listMemories,
    listRecentMemories,
    listUserMemoriesEverywhereAdmin,
    countMemories,
    insertMemory,
    markMemoryEmbedded,
    updateMemory,
    updateVisibleMemory,
    deleteMemory,
    deleteVisibleMemory,
    deleteMemoryAdmin,
    evictOldest,
    fetchMemory,
  )
where

import Data.Int (Int64)
import Data.Maybe (listToMaybe)
import Data.Text (Text)
import Data.Time (UTCTime)
import Database.PostgreSQL.Simple (Only (..), (:.) (..))
import Database.PostgreSQL.Simple.FromRow (FromRow, field, fromRow)
import Effectful
import Effectful.PostgreSQL (WithConnection, execute, query)
import Max.ConversationScope (ConversationScope, conversationStorageId)

data MemoryScope = ScopeGroup | ScopeUser
  deriving stock (Show, Eq)

-- | A semantic-memory partition inside one conversation authorization
-- scope. Group memory is forced to the current conversation id; user memory
-- additionally carries the person it is about, but remains confined to the
-- conversation where it was learned.
data MemoryNamespace = MemoryNamespace
  { namespaceScope :: !MemoryScope,
    namespaceSubjectId :: !Int64,
    namespaceConversation :: !ConversationScope
  }
  deriving stock (Show, Eq)

groupMemoryNamespace :: ConversationScope -> MemoryNamespace
groupMemoryNamespace scope =
  MemoryNamespace ScopeGroup (conversationStorageId scope) scope

userMemoryNamespace :: ConversationScope -> Int64 -> MemoryNamespace
userMemoryNamespace scope uid = MemoryNamespace ScopeUser uid scope

-- | Transitional constructor for code which already has the two legacy
-- scope fields. The group subject argument is intentionally ignored: a
-- caller cannot turn a model-provided group id into authority.
memoryNamespace :: ConversationScope -> MemoryScope -> Int64 -> MemoryNamespace
memoryNamespace scope ScopeGroup _ = groupMemoryNamespace scope
memoryNamespace scope ScopeUser uid = userMemoryNamespace scope uid

namespaceParts :: MemoryNamespace -> (Text, Int64, Int64)
namespaceParts ns =
  ( scopeText ns.namespaceScope,
    ns.namespaceSubjectId,
    conversationStorageId ns.namespaceConversation
  )

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
  MemoryNamespace ->
  Eff es [MemoryItem]
listMemories ns =
  query
    "SELECT id, scope, scope_id, content, updated_at \
    \  FROM memories \
    \  WHERE scope = ? AND scope_id = ? \
    \    AND (scope = 'group' OR source_group_id = ?) \
    \  ORDER BY id"
    (namespaceParts ns)

-- | The @limit@ most recently touched entries of one scope, returned
-- oldest-first like 'listMemories'.  The prompt's @[memories]@ block
-- reads this — injection is capped, while the tools and the extractor
-- keep reading whole scopes.
listRecentMemories ::
  (WithConnection :> es, IOE :> es) =>
  MemoryNamespace ->
  Int ->
  Eff es [MemoryItem]
listRecentMemories ns limit = do
  let (scope, sid, gid) = namespaceParts ns
  rows <-
    query
      "SELECT id, scope, scope_id, content, updated_at \
      \  FROM memories \
      \  WHERE scope = ? AND scope_id = ? \
      \    AND (scope = 'group' OR source_group_id = ?) \
      \  ORDER BY updated_at DESC, id DESC LIMIT ?"
      (scope, sid, gid, limit)
  pure (reverse rows)

-- | Privileged admin view of every memory about one person, paired with its
-- source conversation. Not for commands, prompts, tools, or extractors.
listUserMemoriesEverywhereAdmin ::
  (WithConnection :> es, IOE :> es) =>
  Int64 ->
  Eff es [(MemoryItem, Maybe Int64)]
listUserMemoriesEverywhereAdmin uid = do
  rows <-
    query
      "SELECT id, scope, scope_id, content, updated_at, source_group_id \
      \  FROM memories WHERE scope = 'user' AND scope_id = ? \
      \  ORDER BY source_group_id NULLS FIRST, id"
      (Only uid)
  pure [(m, g) | (m :. Only g) <- rows]

-- | Counts what 'listMemories' would return, so the per-scope cap is
-- measured over the same rows the prompt actually sees.
countMemories ::
  (WithConnection :> es, IOE :> es) =>
  MemoryNamespace ->
  Eff es Int
countMemories ns = do
  rows <-
    query
      "SELECT count(*) FROM memories \
      \ WHERE scope = ? AND scope_id = ? \
      \   AND (scope = 'group' OR source_group_id = ?)"
      (namespaceParts ns)
  pure $ case rows of
    [Only (n :: Int64)] -> fromIntegral n
    _ -> 0

-- | Insert and return the new id.
insertMemory ::
  (WithConnection :> es, IOE :> es) =>
  MemoryNamespace ->
  Text ->
  Eff es Int64
insertMemory ns content = do
  let (scope, sid, gid) = namespaceParts ns
  rows <-
    query
      "INSERT INTO memories (scope, scope_id, content, source_group_id) \
      \  VALUES (?, ?, ?, ?) RETURNING id"
      (scope, sid, content, gid)
  pure $ case rows of
    [Only n] -> n
    _ -> 0 -- unreachable: RETURNING on a successful insert yields one row

-- | Attach an embedding to the exact content row just inserted or embedded.
-- Embedding model/hash metadata is added in the later embedding-lifecycle
-- migration; the namespace predicate already prevents a stale worker or
-- hallucinated id from touching another conversation.
markMemoryEmbedded ::
  (WithConnection :> es, IOE :> es) =>
  MemoryNamespace ->
  Int64 ->
  Text ->
  Eff es Bool
markMemoryEmbedded ns mid vector = do
  let (scope, sid, gid) = namespaceParts ns
  n <-
    execute
      "UPDATE memories SET embedding = ?::vector \
      \  WHERE id = ? AND scope = ? AND scope_id = ? \
      \    AND (scope = 'group' OR source_group_id = ?)"
      (vector, mid, scope, sid, gid)
  pure (n > 0)

-- | Returns 'False' when the id doesn't exist.
updateMemory ::
  (WithConnection :> es, IOE :> es) =>
  MemoryNamespace ->
  Int64 ->
  Text ->
  Eff es Bool
updateMemory ns mid content = do
  let (scope, sid, gid) = namespaceParts ns
  n <-
    execute
      "UPDATE memories \
      \  SET content = ?, embedding = NULL, updated_at = now() \
      \  WHERE id = ? AND scope = ? AND scope_id = ? \
      \    AND (scope = 'group' OR source_group_id = ?)"
      (content, mid, scope, sid, gid)
  pure (n > 0)

-- | Update a memory visible in the current conversation, regardless of
-- which person inside that conversation it is about. This is the safe
-- boundary for model/extractor operations that return only a memory id.
updateVisibleMemory ::
  (WithConnection :> es, IOE :> es) =>
  ConversationScope ->
  Int64 ->
  Text ->
  Eff es Bool
updateVisibleMemory scope mid content = do
  let gid = conversationStorageId scope
  n <-
    execute
      "UPDATE memories \
      \  SET content = ?, embedding = NULL, updated_at = now() \
      \  WHERE id = ? \
      \    AND ((scope = 'group' AND scope_id = ?) \
      \      OR (scope = 'user' AND source_group_id = ?))"
      (content, mid, gid, gid)
  pure (n > 0)

-- | Delete only when @id@ belongs to the authorized namespace.
deleteMemory ::
  (WithConnection :> es, IOE :> es) =>
  MemoryNamespace ->
  Int64 ->
  Eff es Bool
deleteMemory ns mid = do
  let (scope, sid, gid) = namespaceParts ns
  n <-
    execute
      "DELETE FROM memories \
      \  WHERE id = ? AND scope = ? AND scope_id = ? \
      \    AND (scope = 'group' OR source_group_id = ?)"
      (mid, scope, sid, gid)
  pure (n > 0)

-- | Delete a memory only when the current conversation can see it.
deleteVisibleMemory ::
  (WithConnection :> es, IOE :> es) =>
  ConversationScope ->
  Int64 ->
  Eff es Bool
deleteVisibleMemory scope mid = do
  let gid = conversationStorageId scope
  n <-
    execute
      "DELETE FROM memories \
      \  WHERE id = ? \
      \    AND ((scope = 'group' AND scope_id = ?) \
      \      OR (scope = 'user' AND source_group_id = ?))"
      (mid, gid, gid)
  pure (n > 0)

-- | Privileged deletion for the authenticated admin API.
deleteMemoryAdmin :: (WithConnection :> es, IOE :> es) => Int64 -> Eff es Bool
deleteMemoryAdmin mid = do
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
  MemoryNamespace ->
  Eff es (Maybe (Int64, Text))
evictOldest ns = do
  rows <-
    query
      "DELETE FROM memories WHERE id = \
      \   (SELECT id FROM memories \
      \     WHERE scope = ? AND scope_id = ? \
      \       AND (scope = 'group' OR source_group_id = ?) \
      \     ORDER BY updated_at ASC, id ASC LIMIT 1) \
      \ RETURNING id, content"
      (namespaceParts ns)
  pure (listToMaybe rows)

fetchMemory ::
  (WithConnection :> es, IOE :> es) =>
  MemoryNamespace ->
  Int64 ->
  Eff es (Maybe MemoryItem)
fetchMemory ns mid = do
  let (scope, sid, gid) = namespaceParts ns
  rows <-
    query
      "SELECT id, scope, scope_id, content, updated_at \
      \  FROM memories \
      \  WHERE id = ? AND scope = ? AND scope_id = ? \
      \    AND (scope = 'group' OR source_group_id = ?)"
      (mid, scope, sid, gid)
  pure (listToMaybe rows)
