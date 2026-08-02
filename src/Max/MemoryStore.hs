-- |
-- Scoped, versioned semantic-memory storage.
--
-- @memories@ is the current projection for efficient prompt/retrieval reads;
-- every semantic or lifecycle mutation appends a @memory_versions@ snapshot
-- and @memory_mutations@ audit row in the same SQL statement.  Evidence is
-- append-only and carries the source conversation independently from the
-- subject namespace.  No caller receives an unscoped UPDATE primitive.
module Max.MemoryStore
  ( MemoryScope (..),
    MemoryNamespace,
    MemoryId (..),
    MemoryVersion (..),
    ExpectedVersion (..),
    MemoryLifecycle (..),
    MemoryCategory (..),
    MemoryActorKind (..),
    MemoryActor (..),
    MemoryEvidence (..),
    MemoryDraft (..),
    MemoryUpdate (..),
    MemoryMutationResult (..),
    MemoryItem (..),
    MemoryMaintenanceEntry (..),
    MemoryMaintenanceCandidate (..),
    PendingMemoryEmbedding (..),
    scopeText,
    parseScope,
    lifecycleText,
    categoryText,
    parseCategory,
    groupMemoryNamespace,
    userMemoryNamespace,
    memoryNamespace,
    listMemories,
    listRecentMemories,
    listUserMemoriesEverywhereAdmin,
    countMemories,
    fetchMemory,
    fetchVisibleMemory,
    fetchMemoryAdmin,
    createMemory,
    updateMemory,
    updateVisibleMemory,
    archiveMemory,
    archiveMemoryWithEvidence,
    archiveVisibleMemory,
    archiveMemoryAdmin,
    makeMemoryPermanent,
    supersedeMemory,
    supersedeMemoryWithEvidence,
    evictOldest,
    invalidateMemoryEmbeddingsInConversation,
    markMemoryEmbedded,
    listPendingMemoryEmbeddings,
    markPendingMemoryEmbedded,
    findExactMemory,
    findNearestMemory,
    searchVisibleMemories,
    listMemoryMaintenanceCandidates,
    listMemoryMaintenanceEntries,
  )
where

import Control.Exception (throwIO)
import Control.Monad (unless)
import Data.Aeson (FromJSON, ToJSON)
import Data.Int (Int64)
import Data.Maybe (listToMaybe)
import Data.String (fromString)
import Data.Text (Text)
import Data.Time (UTCTime)
import Database.PostgreSQL.Simple (Only (..), Query, (:.) (..))
import Database.PostgreSQL.Simple.FromField (FromField)
import Database.PostgreSQL.Simple.FromRow (FromRow, field, fromRow)
import Database.PostgreSQL.Simple.ToField (ToField)
import Database.PostgreSQL.Simple.ToField qualified as PG
import Effectful
import Effectful.PostgreSQL (WithConnection, execute, query)
import Max.ConversationScope
  ( ConversationScope,
    RecallPolicy,
    conversationStorageId,
    recallConversationScope,
  )
import Max.Embedding (EmbeddingRecord (..))

newtype MemoryId = MemoryId {unMemoryId :: Int64}
  deriving stock (Show, Eq, Ord)
  deriving newtype (FromField, ToField, FromJSON, ToJSON)

newtype MemoryVersion = MemoryVersion {unMemoryVersion :: Int64}
  deriving stock (Show, Eq, Ord)
  deriving newtype (FromField, ToField, FromJSON, ToJSON)

newtype ExpectedVersion = ExpectedVersion {unExpectedVersion :: MemoryVersion}
  deriving stock (Show, Eq)

data MemoryScope = ScopeGroup | ScopeUser
  deriving stock (Show, Eq)

data MemoryLifecycle
  = MemoryActive
  | MemoryPermanent
  | MemoryArchived
  | MemorySuperseded
  deriving stock (Show, Eq)

data MemoryCategory
  = PersonFact
  | Preference
  | GroupConvention
  | OngoingProject
  | Commitment
  | Decision
  | RunningJoke
  | RelationshipContext
  deriving stock (Show, Eq)

-- | Who authorized a mutation.  Automatic actors are deliberately denied
-- mutation/archive authority over permanent memories in SQL predicates.
data MemoryActorKind
  = ActorAgentTool
  | ActorExtractor
  | ActorDreamer
  | ActorCommand
  | ActorAdmin
  | ActorHistorian
  deriving stock (Show, Eq)

data MemoryActor = MemoryActor
  { actorKind :: !MemoryActorKind,
    actorPrincipalId :: !(Maybe Int64),
    actorReason :: !(Maybe Text)
  }
  deriving stock (Show, Eq)

-- | Evidence constructors require a host-created 'ConversationScope'; an LLM
-- can propose content or cite handles, but cannot choose its origin scope.
data MemoryEvidence
  = LegacyEvidence !(Maybe ConversationScope) !Text
  | MessageEvidence !ConversationScope !(Maybe Int64) !Int64
  | RangeEvidence !ConversationScope !Int64 !Int64
  | EpisodeEvidence !ConversationScope !Int64
  | MaintenanceEvidence !ConversationScope !Text
  | AdminEvidence !(Maybe ConversationScope) !Text
  deriving stock (Show, Eq)

data MemoryDraft = MemoryDraft
  { draftContent :: !Text,
    draftLifecycle :: !MemoryLifecycle,
    draftCategory :: !(Maybe MemoryCategory),
    draftEvidence :: !MemoryEvidence
  }
  deriving stock (Show, Eq)

data MemoryUpdate = MemoryUpdate
  { updateContent :: !Text,
    updateEvidence :: !MemoryEvidence
  }
  deriving stock (Show, Eq)

data MemoryMutationResult
  = MemoryMutationApplied !MemoryItem
  | -- | The id/version/scope/lifecycle predicate did not authorize a write.
    -- Deliberately does not distinguish an invisible id from a CAS conflict.
    MemoryMutationRejected
  deriving stock (Show, Eq)

-- | A semantic-memory partition inside one conversation authorization scope.
-- The subject (group/person) and origin conversation remain independent.
data MemoryNamespace = MemoryNamespace
  { namespaceScope :: !MemoryScope,
    namespaceSubjectId :: !Int64,
    namespaceConversation :: !ConversationScope
  }
  deriving stock (Show, Eq)

data MemoryItem = MemoryItem
  { memId :: !MemoryId,
    memVersion :: !MemoryVersion,
    memScope :: !Text,
    memScopeId :: !Int64,
    memContent :: !Text,
    memLifecycle :: !Text,
    memCategory :: !(Maybe Text),
    memUpdatedAt :: !UTCTime
  }
  deriving stock (Show, Eq)

instance FromRow MemoryItem where
  fromRow =
    MemoryItem
      <$> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field

data MemoryMaintenanceCandidate = MemoryMaintenanceCandidate
  { maintenanceScope :: !Text,
    maintenanceSubjectId :: !Int64,
    maintenanceConversationId :: !Int64,
    maintenanceCount :: !Int
  }
  deriving stock (Show, Eq)

-- | One current memory projection plus the newest evidence attached to that
-- exact version.  Dreamer decisions are made from this shape rather than from
-- content/date alone, so provenance is present both before and after a
-- maintenance mutation.
data MemoryMaintenanceEntry = MemoryMaintenanceEntry
  { mmeMemory :: !MemoryItem,
    mmeEvidenceKind :: !(Maybe Text),
    mmeSourceConversationId :: !(Maybe Int64),
    mmeSourcePrincipalId :: !(Maybe Int64),
    mmeSourceMessageId :: !(Maybe Int64),
    mmeSourceStartIngestSeq :: !(Maybe Int64),
    mmeSourceEndIngestSeq :: !(Maybe Int64),
    mmeSourceEpisodeId :: !(Maybe Int64),
    mmeEvidenceNote :: !(Maybe Text),
    mmeEvidenceAt :: !(Maybe UTCTime)
  }
  deriving stock (Show, Eq)

instance FromRow MemoryMaintenanceEntry where
  fromRow =
    MemoryMaintenanceEntry
      <$> ( MemoryItem
              <$> field
              <*> field
              <*> field
              <*> field
              <*> field
              <*> field
              <*> field
              <*> field
          )
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field

data PendingMemoryEmbedding = PendingMemoryEmbedding
  { pendingMemoryId :: !MemoryId,
    pendingMemoryVersion :: !MemoryVersion,
    pendingMemoryContent :: !Text
  }
  deriving stock (Show, Eq)

instance FromRow PendingMemoryEmbedding where
  fromRow = PendingMemoryEmbedding <$> field <*> field <*> field

scopeText :: MemoryScope -> Text
scopeText ScopeGroup = "group"
scopeText ScopeUser = "user"

parseScope :: Text -> Maybe MemoryScope
parseScope "group" = Just ScopeGroup
parseScope "user" = Just ScopeUser
parseScope _ = Nothing

lifecycleText :: MemoryLifecycle -> Text
lifecycleText MemoryActive = "active"
lifecycleText MemoryPermanent = "permanent"
lifecycleText MemoryArchived = "archived"
lifecycleText MemorySuperseded = "superseded"

categoryText :: MemoryCategory -> Text
categoryText PersonFact = "person_fact"
categoryText Preference = "preference"
categoryText GroupConvention = "group_convention"
categoryText OngoingProject = "ongoing_project"
categoryText Commitment = "commitment"
categoryText Decision = "decision"
categoryText RunningJoke = "running_joke"
categoryText RelationshipContext = "relationship_context"

parseCategory :: Text -> Maybe MemoryCategory
parseCategory = \case
  "person_fact" -> Just PersonFact
  "preference" -> Just Preference
  "group_convention" -> Just GroupConvention
  "ongoing_project" -> Just OngoingProject
  "commitment" -> Just Commitment
  "decision" -> Just Decision
  "running_joke" -> Just RunningJoke
  "relationship_context" -> Just RelationshipContext
  _ -> Nothing

actorText :: MemoryActorKind -> Text
actorText ActorAgentTool = "agent_tool"
actorText ActorExtractor = "extractor"
actorText ActorDreamer = "dreamer"
actorText ActorCommand = "command"
actorText ActorAdmin = "admin"
actorText ActorHistorian = "historian"

actorMayMutatePermanent :: MemoryActor -> Bool
actorMayMutatePermanent actor =
  actor.actorKind `elem` [ActorAgentTool, ActorCommand, ActorAdmin]

groupMemoryNamespace :: ConversationScope -> MemoryNamespace
groupMemoryNamespace scope =
  MemoryNamespace ScopeGroup (conversationStorageId scope) scope

userMemoryNamespace :: ConversationScope -> Int64 -> MemoryNamespace
userMemoryNamespace scope uid = MemoryNamespace ScopeUser uid scope

memoryNamespace :: ConversationScope -> MemoryScope -> Int64 -> MemoryNamespace
memoryNamespace scope ScopeGroup _ = groupMemoryNamespace scope
memoryNamespace scope ScopeUser uid = userMemoryNamespace scope uid

namespaceParts :: MemoryNamespace -> (Text, Int64, Int64)
namespaceParts ns =
  ( scopeText ns.namespaceScope,
    ns.namespaceSubjectId,
    conversationStorageId ns.namespaceConversation
  )

listMemories ::
  (WithConnection :> es, IOE :> es) =>
  MemoryNamespace ->
  Eff es [MemoryItem]
listMemories ns =
  query
    "SELECT id, version, scope, scope_id, content, lifecycle, category, updated_at \
    \ FROM memories \
    \ WHERE scope = ? AND scope_id = ? \
    \   AND (scope = 'group' OR source_group_id = ?) \
    \   AND lifecycle IN ('active', 'permanent') \
    \ ORDER BY id"
    (namespaceParts ns)

listRecentMemories ::
  (WithConnection :> es, IOE :> es) =>
  MemoryNamespace ->
  Int ->
  Eff es [MemoryItem]
listRecentMemories ns limit = do
  let (scope, sid, gid) = namespaceParts ns
  rows <-
    query
      "SELECT id, version, scope, scope_id, content, lifecycle, category, updated_at \
      \ FROM memories \
      \ WHERE scope = ? AND scope_id = ? \
      \   AND (scope = 'group' OR source_group_id = ?) \
      \   AND lifecycle IN ('active', 'permanent') \
      \ ORDER BY updated_at DESC, id DESC LIMIT ?"
      (scope, sid, gid, limit)
  pure (reverse rows)

listUserMemoriesEverywhereAdmin ::
  (WithConnection :> es, IOE :> es) =>
  Int64 ->
  Eff es [(MemoryItem, Maybe Int64)]
listUserMemoriesEverywhereAdmin uid = do
  rows <-
    query
      "SELECT id, version, scope, scope_id, content, lifecycle, category, updated_at, source_group_id \
      \ FROM memories WHERE scope = 'user' AND scope_id = ? \
      \ ORDER BY source_group_id NULLS FIRST, id"
      (Only uid)
  pure [(m, g) | (m :. Only g) <- rows]

countMemories ::
  (WithConnection :> es, IOE :> es) =>
  MemoryNamespace ->
  Eff es Int
countMemories ns = do
  rows <-
    query
      "SELECT count(*) FROM memories \
      \ WHERE scope = ? AND scope_id = ? \
      \   AND (scope = 'group' OR source_group_id = ?) \
      \   AND lifecycle IN ('active', 'permanent')"
      (namespaceParts ns)
  pure $ case rows of
    [Only (n :: Int64)] -> fromIntegral n
    _ -> 0

fetchMemory ::
  (WithConnection :> es, IOE :> es) =>
  MemoryNamespace ->
  MemoryId ->
  Eff es (Maybe MemoryItem)
fetchMemory ns mid = do
  let (scope, sid, gid) = namespaceParts ns
  rows <-
    query
      "SELECT id, version, scope, scope_id, content, lifecycle, category, updated_at \
      \ FROM memories \
      \ WHERE id = ? AND scope = ? AND scope_id = ? \
      \   AND (scope = 'group' OR source_group_id = ?) \
      \   AND lifecycle IN ('active', 'permanent')"
      (mid, scope, sid, gid)
  pure (listToMaybe rows)

fetchVisibleMemory ::
  (WithConnection :> es, IOE :> es) =>
  RecallPolicy ->
  MemoryId ->
  Eff es (Maybe MemoryItem)
fetchVisibleMemory policy mid = do
  let gid = conversationStorageId (recallConversationScope policy)
  rows <-
    query
      "SELECT id, version, scope, scope_id, content, lifecycle, category, updated_at \
      \ FROM memories \
      \ WHERE id = ? \
      \   AND ((scope = 'group' AND scope_id = ?) \
      \     OR (scope = 'user' AND source_group_id = ?)) \
      \   AND lifecycle IN ('active', 'permanent')"
      (mid, gid, gid)
  pure (listToMaybe rows)

fetchMemoryAdmin ::
  (WithConnection :> es, IOE :> es) =>
  MemoryId ->
  Eff es (Maybe MemoryItem)
fetchMemoryAdmin mid = do
  rows <-
    query
      "SELECT id, version, scope, scope_id, content, lifecycle, category, updated_at \
      \ FROM memories WHERE id = ?"
      (Only mid)
  pure (listToMaybe rows)

createMemory ::
  (WithConnection :> es, IOE :> es) =>
  MemoryActor ->
  MemoryNamespace ->
  MemoryDraft ->
  Eff es MemoryItem
createMemory actor ns draft = do
  let (scope, sid, gid) = namespaceParts ns
      evidence = evidenceParts draft.draftEvidence
      params =
        [ PG.toField scope,
          PG.toField sid,
          PG.toField draft.draftContent,
          PG.toField gid,
          PG.toField (lifecycleText draft.draftLifecycle),
          PG.toField (categoryText <$> draft.draftCategory)
        ]
          <> evidenceActions evidence
          <> [ PG.toField (actorText actor.actorKind),
               PG.toField actor.actorPrincipalId,
               PG.toField gid,
               PG.toField actor.actorReason
             ]
  unless (createLifecycleAllowed actor draft.draftLifecycle) $
    storeInvariantFailure "createMemory: actor cannot create the requested lifecycle"
  unless (evidenceAllowed actor gid draft.draftEvidence) $
    storeInvariantFailure "createMemory: evidence origin does not match the namespace"
  rows <-
    query
      "WITH inserted AS ( \
      \  INSERT INTO memories \
      \    (scope, scope_id, content, source_group_id, lifecycle, category) \
      \  VALUES (?, ?, ?, ?, ?, ?) \
      \  RETURNING id, version, scope, scope_id, content, lifecycle, category, \
      \            superseded_by, updated_at \
      \), versioned AS ( \
      \  INSERT INTO memory_versions \
      \    (memory_id, version, content, lifecycle, category, superseded_by, created_at) \
      \  SELECT id, version, content, lifecycle, category, superseded_by, updated_at \
      \  FROM inserted \
      \), evidenced AS ( \
      \  INSERT INTO memory_evidence \
      \    (memory_id, memory_version, evidence_kind, source_conversation_id, \
      \     source_principal_id, source_message_id, source_start_ingest_seq, \
      \     source_end_ingest_seq, source_episode_id, note) \
      \  SELECT id, version, ?, ?, ?, ?, ?, ?, ?, ? FROM inserted \
      \), audited AS ( \
      \  INSERT INTO memory_mutations \
      \    (memory_id, from_version, to_version, operation, actor_kind, \
      \     actor_principal_id, conversation_id, reason) \
      \  SELECT id, NULL, version, 'create', ?, ?, ?, ? FROM inserted \
      \) \
      \ SELECT id, version, scope, scope_id, content, lifecycle, category, updated_at \
      \ FROM inserted"
      params
  expectOne "createMemory" rows

updateMemory ::
  (WithConnection :> es, IOE :> es) =>
  MemoryActor ->
  MemoryNamespace ->
  MemoryId ->
  ExpectedVersion ->
  MemoryUpdate ->
  Eff es MemoryMutationResult
updateMemory actor ns mid expected update = do
  let (scope, sid, gid) = namespaceParts ns
  runContentUpdate
    actor
    (NamespaceTarget mid expected scope sid gid)
    update

updateVisibleMemory ::
  (WithConnection :> es, IOE :> es) =>
  MemoryActor ->
  RecallPolicy ->
  MemoryId ->
  ExpectedVersion ->
  MemoryUpdate ->
  Eff es MemoryMutationResult
updateVisibleMemory actor policy mid expected update =
  runContentUpdate actor (VisibleTarget mid expected gid) update
  where
    gid = conversationStorageId (recallConversationScope policy)

data MutationTarget
  = NamespaceTarget !MemoryId !ExpectedVersion !Text !Int64 !Int64
  | VisibleTarget !MemoryId !ExpectedVersion !Int64
  | AdminTarget !MemoryId !ExpectedVersion

runContentUpdate ::
  (WithConnection :> es, IOE :> es) =>
  MemoryActor ->
  MutationTarget ->
  MemoryUpdate ->
  Eff es MemoryMutationResult
runContentUpdate actor target update = do
  let (whereSql, targetActions, conversationId) = targetPredicate target
      evidence = evidenceParts update.updateEvidence
      sql =
        "WITH updated AS ( "
          <> " UPDATE memories SET content = ?, version = version + 1, "
          <> " embedding = NULL, embedding_model = NULL, embedding_dimensions = NULL, "
          <> " embedding_content_hash = NULL, embedding_updated_at = NULL, updated_at = now() "
          <> whereSql
          <> " AND lifecycle IN ('active', 'permanent') "
          <> " AND (? OR lifecycle <> 'permanent') "
          <> " RETURNING id, version, scope, scope_id, content, lifecycle, category, superseded_by, updated_at"
          <> "), versioned AS ("
          <> " INSERT INTO memory_versions "
          <> " (memory_id, version, content, lifecycle, category, superseded_by, created_at) "
          <> " SELECT id, version, content, lifecycle, category, superseded_by, updated_at FROM updated"
          <> "), evidenced AS ("
          <> " INSERT INTO memory_evidence "
          <> " (memory_id, memory_version, evidence_kind, source_conversation_id, source_principal_id, "
          <> " source_message_id, source_start_ingest_seq, source_end_ingest_seq, source_episode_id, note) "
          <> " SELECT id, version, ?, ?, ?, ?, ?, ?, ?, ? FROM updated"
          <> "), audited AS ("
          <> " INSERT INTO memory_mutations "
          <> " (memory_id, from_version, to_version, operation, actor_kind, actor_principal_id, conversation_id, reason) "
          <> " SELECT id, version - 1, version, 'update', ?, ?, ?, ? FROM updated"
          <> ") SELECT id, version, scope, scope_id, content, lifecycle, category, updated_at FROM updated"
      params =
        [PG.toField update.updateContent]
          <> targetActions
          <> [PG.toField (actorMayMutatePermanent actor)]
          <> evidenceActions evidence
          <> [ PG.toField (actorText actor.actorKind),
               PG.toField actor.actorPrincipalId,
               PG.toField conversationId,
               PG.toField actor.actorReason
             ]
  if evidenceAllowed actor conversationId update.updateEvidence
    then mutationResult <$> query (fromStringQuery sql) params
    else pure MemoryMutationRejected

targetPredicate :: MutationTarget -> (String, [PG.Action], Int64)
targetPredicate = \case
  NamespaceTarget mid (ExpectedVersion expected) scope sid gid ->
    ( " WHERE id = ? AND version = ? AND scope = ? AND scope_id = ? \
      \ AND (scope = 'group' OR source_group_id = ?)",
      [PG.toField mid, PG.toField expected, PG.toField scope, PG.toField sid, PG.toField gid],
      gid
    )
  VisibleTarget mid (ExpectedVersion expected) gid ->
    ( " WHERE id = ? AND version = ? \
      \ AND ((scope = 'group' AND scope_id = ?) \
      \   OR (scope = 'user' AND source_group_id = ?))",
      [PG.toField mid, PG.toField expected, PG.toField gid, PG.toField gid],
      gid
    )
  AdminTarget mid (ExpectedVersion expected) ->
    (" WHERE id = ? AND version = ?", [PG.toField mid, PG.toField expected], 0)

archiveMemory ::
  (WithConnection :> es, IOE :> es) =>
  MemoryActor ->
  MemoryNamespace ->
  MemoryId ->
  ExpectedVersion ->
  Eff es MemoryMutationResult
archiveMemory actor ns mid expected = do
  let (scope, sid, gid) = namespaceParts ns
  runLifecycleMutation actor "archive" MemoryArchived Nothing (NamespaceTarget mid expected scope sid gid)

archiveMemoryWithEvidence ::
  (WithConnection :> es, IOE :> es) =>
  MemoryActor ->
  MemoryNamespace ->
  MemoryId ->
  ExpectedVersion ->
  MemoryEvidence ->
  Eff es MemoryMutationResult
archiveMemoryWithEvidence actor ns mid expected evidence = do
  let (scope, sid, gid) = namespaceParts ns
  runLifecycleMutationWithEvidence
    actor
    "archive"
    MemoryArchived
    Nothing
    (NamespaceTarget mid expected scope sid gid)
    (Just evidence)

archiveVisibleMemory ::
  (WithConnection :> es, IOE :> es) =>
  MemoryActor ->
  RecallPolicy ->
  MemoryId ->
  ExpectedVersion ->
  Eff es MemoryMutationResult
archiveVisibleMemory actor policy mid expected =
  runLifecycleMutation actor "archive" MemoryArchived Nothing (VisibleTarget mid expected gid)
  where
    gid = conversationStorageId (recallConversationScope policy)

archiveMemoryAdmin ::
  (WithConnection :> es, IOE :> es) =>
  MemoryActor ->
  MemoryId ->
  ExpectedVersion ->
  Eff es MemoryMutationResult
archiveMemoryAdmin actor mid expected =
  runLifecycleMutation actor "archive" MemoryArchived Nothing (AdminTarget mid expected)

makeMemoryPermanent ::
  (WithConnection :> es, IOE :> es) =>
  MemoryActor ->
  MemoryNamespace ->
  MemoryId ->
  ExpectedVersion ->
  Eff es MemoryMutationResult
makeMemoryPermanent actor ns mid expected = do
  let (scope, sid, gid) = namespaceParts ns
  if actorMayMutatePermanent actor
    then runLifecycleMutation actor "make_permanent" MemoryPermanent Nothing (NamespaceTarget mid expected scope sid gid)
    else pure MemoryMutationRejected

supersedeMemory ::
  (WithConnection :> es, IOE :> es) =>
  MemoryActor ->
  MemoryNamespace ->
  MemoryId ->
  ExpectedVersion ->
  MemoryId ->
  Eff es MemoryMutationResult
supersedeMemory actor ns mid expected replacement = do
  let (scope, sid, gid) = namespaceParts ns
  if mid == replacement
    then pure MemoryMutationRejected
    else
      runLifecycleMutation
        actor
        "supersede"
        MemorySuperseded
        (Just replacement)
        (NamespaceTarget mid expected scope sid gid)

supersedeMemoryWithEvidence ::
  (WithConnection :> es, IOE :> es) =>
  MemoryActor ->
  MemoryNamespace ->
  MemoryId ->
  ExpectedVersion ->
  MemoryId ->
  MemoryEvidence ->
  Eff es MemoryMutationResult
supersedeMemoryWithEvidence actor ns mid expected replacement evidence = do
  let (scope, sid, gid) = namespaceParts ns
  if mid == replacement
    then pure MemoryMutationRejected
    else
      runLifecycleMutationWithEvidence
        actor
        "supersede"
        MemorySuperseded
        (Just replacement)
        (NamespaceTarget mid expected scope sid gid)
        (Just evidence)

runLifecycleMutation ::
  (WithConnection :> es, IOE :> es) =>
  MemoryActor ->
  Text ->
  MemoryLifecycle ->
  Maybe MemoryId ->
  MutationTarget ->
  Eff es MemoryMutationResult
runLifecycleMutation actor operation lifecycle replacement target = do
  runLifecycleMutationWithEvidence actor operation lifecycle replacement target Nothing

runLifecycleMutationWithEvidence ::
  (WithConnection :> es, IOE :> es) =>
  MemoryActor ->
  Text ->
  MemoryLifecycle ->
  Maybe MemoryId ->
  MutationTarget ->
  Maybe MemoryEvidence ->
  Eff es MemoryMutationResult
runLifecycleMutationWithEvidence actor operation lifecycle replacement target mEvidence = do
  let (whereSql, targetActions, conversationId) = targetPredicate target
      (replacementSql, replacementActions) = replacementPredicate target replacement
      evidenceSql = case mEvidence of
        Nothing -> ""
        Just _ ->
          ", evidenced AS ( INSERT INTO memory_evidence "
            <> " (memory_id, memory_version, evidence_kind, source_conversation_id, source_principal_id, "
            <> " source_message_id, source_start_ingest_seq, source_end_ingest_seq, source_episode_id, note) "
            <> " SELECT id, version, ?, ?, ?, ?, ?, ?, ?, ? FROM updated)"
      sql =
        "WITH updated AS ( UPDATE memories "
          <> " SET lifecycle = ?, superseded_by = ?, version = version + 1, updated_at = now() "
          <> whereSql
          <> replacementSql
          <> " AND lifecycle IN ('active', 'permanent') "
          <> " AND (? OR lifecycle <> 'permanent') "
          <> " RETURNING id, version, scope, scope_id, content, lifecycle, category, superseded_by, updated_at"
          <> "), versioned AS ( INSERT INTO memory_versions "
          <> " (memory_id, version, content, lifecycle, category, superseded_by, created_at) "
          <> " SELECT id, version, content, lifecycle, category, superseded_by, updated_at FROM updated"
          <> ")"
          <> evidenceSql
          <> ", audited AS ( INSERT INTO memory_mutations "
          <> " (memory_id, from_version, to_version, operation, actor_kind, actor_principal_id, conversation_id, reason) "
          <> " SELECT id, version - 1, version, ?, ?, ?, NULLIF(?, 0), ? FROM updated"
          <> ") SELECT id, version, scope, scope_id, content, lifecycle, category, updated_at FROM updated"
      params =
        [PG.toField (lifecycleText lifecycle), PG.toField replacement]
          <> targetActions
          <> replacementActions
          <> [PG.toField (actorMayMutatePermanent actor)]
          <> maybe [] (evidenceActions . evidenceParts) mEvidence
          <> [ PG.toField operation,
               PG.toField (actorText actor.actorKind),
               PG.toField actor.actorPrincipalId,
               PG.toField conversationId,
               PG.toField actor.actorReason
             ]
  if maybe True (evidenceAllowed actor conversationId) mEvidence
    then mutationResult <$> query (fromStringQuery sql) params
    else pure MemoryMutationRejected

replacementPredicate :: MutationTarget -> Maybe MemoryId -> (String, [PG.Action])
replacementPredicate _ Nothing = ("", [])
replacementPredicate target (Just replacement) = case target of
  NamespaceTarget _ _ scope sid gid ->
    ( " AND EXISTS (SELECT 1 FROM memories replacement \
      \ WHERE replacement.id = ? AND replacement.scope = ? AND replacement.scope_id = ? \
      \   AND (replacement.scope = 'group' OR replacement.source_group_id = ?) \
      \   AND replacement.lifecycle IN ('active', 'permanent'))",
      [PG.toField replacement, PG.toField scope, PG.toField sid, PG.toField gid]
    )
  VisibleTarget _ _ gid ->
    ( " AND EXISTS (SELECT 1 FROM memories replacement \
      \ WHERE replacement.id = ? \
      \   AND ((replacement.scope = 'group' AND replacement.scope_id = ?) \
      \     OR (replacement.scope = 'user' AND replacement.source_group_id = ?)) \
      \   AND replacement.lifecycle IN ('active', 'permanent'))",
      [PG.toField replacement, PG.toField gid, PG.toField gid]
    )
  AdminTarget {} ->
    ( " AND EXISTS (SELECT 1 FROM memories replacement \
      \ WHERE replacement.id = ? AND replacement.lifecycle IN ('active', 'permanent'))",
      [PG.toField replacement]
    )

evictOldest ::
  (WithConnection :> es, IOE :> es) =>
  MemoryActor ->
  MemoryNamespace ->
  Eff es (Maybe MemoryItem)
evictOldest actor ns = do
  let (scope, sid, gid) = namespaceParts ns
  rows <-
    query
      "SELECT id, version, scope, scope_id, content, lifecycle, category, updated_at \
      \ FROM memories \
      \ WHERE scope = ? AND scope_id = ? \
      \   AND (scope = 'group' OR source_group_id = ?) \
      \   AND lifecycle = 'active' \
      \ ORDER BY updated_at ASC, id ASC LIMIT 1"
      (scope, sid, gid)
  case (rows :: [MemoryItem]) of
    [] -> pure Nothing
    candidate : _ ->
      archiveMemory actor ns candidate.memId (ExpectedVersion candidate.memVersion) >>= \case
        MemoryMutationApplied archived -> pure (Just archived)
        MemoryMutationRejected -> pure Nothing

markMemoryEmbedded ::
  (WithConnection :> es, IOE :> es) =>
  MemoryNamespace ->
  MemoryId ->
  ExpectedVersion ->
  Text ->
  EmbeddingRecord ->
  Eff es Bool
markMemoryEmbedded ns mid expected content record = do
  let (scope, sid, gid) = namespaceParts ns
  markEmbeddingWhere
    "id = ? AND version = ? AND content = ? AND scope = ? AND scope_id = ? \
    \ AND (scope = 'group' OR source_group_id = ?)"
    [ PG.toField mid,
      PG.toField expected.unExpectedVersion,
      PG.toField content,
      PG.toField scope,
      PG.toField sid,
      PG.toField gid
    ]
    record

-- | Clear only the derived vector projection owned by one conversation.
-- Content, semantic version, evidence, and lifecycle stay untouched; the
-- ordinary embedding worker will repopulate the row under content-hash CAS.
invalidateMemoryEmbeddingsInConversation ::
  (WithConnection :> es, IOE :> es) =>
  ConversationScope ->
  Eff es Int64
invalidateMemoryEmbeddingsInConversation scope =
  execute
    "UPDATE memories SET embedding = NULL, embedding_model = NULL, embedding_dimensions = NULL, embedding_content_hash = NULL, embedding_updated_at = NULL \
    \ WHERE (scope = 'group' AND scope_id = ?) OR (scope = 'user' AND source_group_id = ?)"
    (conversationStorageId scope, conversationStorageId scope)

listPendingMemoryEmbeddings ::
  (WithConnection :> es, IOE :> es) =>
  Text ->
  Int ->
  Eff es [PendingMemoryEmbedding]
listPendingMemoryEmbeddings modelId limit =
  query
    "SELECT id, version, content FROM memories \
    \ WHERE lifecycle IN ('active', 'permanent') \
    \   AND (embedding IS NULL OR embedding_model IS DISTINCT FROM ?) \
    \ ORDER BY updated_at DESC, id DESC LIMIT ?"
    (modelId, limit)

markPendingMemoryEmbedded ::
  (WithConnection :> es, IOE :> es) =>
  PendingMemoryEmbedding ->
  EmbeddingRecord ->
  Eff es Bool
markPendingMemoryEmbedded pending record =
  markEmbeddingWhere
    "id = ? AND version = ? AND content = ? AND lifecycle IN ('active', 'permanent')"
    [ PG.toField pending.pendingMemoryId,
      PG.toField pending.pendingMemoryVersion,
      PG.toField pending.pendingMemoryContent
    ]
    record

markEmbeddingWhere ::
  (WithConnection :> es, IOE :> es) =>
  String ->
  [PG.Action] ->
  EmbeddingRecord ->
  Eff es Bool
markEmbeddingWhere predicate targetActions record = do
  let sql =
        "UPDATE memories SET embedding = ?::vector, embedding_model = ?, "
          <> "embedding_dimensions = ?, embedding_content_hash = ?, embedding_updated_at = now() WHERE "
          <> predicate
      params =
        [ PG.toField record.erVector,
          PG.toField record.erModelId,
          PG.toField record.erDimensions,
          PG.toField record.erContentHash
        ]
          <> targetActions
  (> 0) <$> execute (fromStringQuery sql) params

findExactMemory ::
  (WithConnection :> es, IOE :> es) =>
  MemoryNamespace ->
  Text ->
  Eff es (Maybe MemoryId)
findExactMemory ns content = do
  let (scope, sid, gid) = namespaceParts ns
  rows <-
    query
      "SELECT id FROM memories \
      \ WHERE scope = ? AND scope_id = ? AND content = ? \
      \   AND (scope = 'group' OR source_group_id = ?) \
      \   AND lifecycle IN ('active', 'permanent') LIMIT 1"
      (scope, sid, content, gid)
  pure (fromOnly <$> listToMaybe rows)

findNearestMemory ::
  (WithConnection :> es, IOE :> es) =>
  MemoryNamespace ->
  EmbeddingRecord ->
  Eff es (Maybe (MemoryId, Double))
findNearestMemory ns record = do
  let (scope, sid, gid) = namespaceParts ns
  rows <-
    query
      "WITH compatible AS MATERIALIZED ( \
      \  SELECT id, embedding FROM memories \
      \  WHERE scope = ? AND scope_id = ? \
      \    AND (scope = 'group' OR source_group_id = ?) \
      \    AND lifecycle IN ('active', 'permanent') \
      \    AND embedding_model = ? AND embedding_dimensions = ? \
      \) \
      \ SELECT id, embedding <=> ?::vector AS distance FROM compatible \
      \ ORDER BY distance LIMIT 1"
      (scope, sid, gid, record.erModelId, record.erDimensions, record.erVector)
  pure (listToMaybe rows)

searchVisibleMemories ::
  (WithConnection :> es, IOE :> es) =>
  RecallPolicy ->
  EmbeddingRecord ->
  Int ->
  Eff es [MemoryItem]
searchVisibleMemories policy record limit = do
  let gid = conversationStorageId (recallConversationScope policy)
  query
    "WITH compatible AS MATERIALIZED ( \
    \  SELECT id, version, scope, scope_id, content, lifecycle, category, updated_at, embedding \
    \  FROM memories \
    \  WHERE ((scope = 'group' AND scope_id = ?) \
    \      OR (scope = 'user' AND source_group_id = ?)) \
    \    AND lifecycle IN ('active', 'permanent') \
    \    AND embedding_model = ? AND embedding_dimensions = ? \
    \) \
    \ SELECT id, version, scope, scope_id, content, lifecycle, category, updated_at \
    \ FROM compatible ORDER BY embedding <=> ?::vector LIMIT ?"
    (gid, gid, record.erModelId, record.erDimensions, record.erVector, limit)

listMemoryMaintenanceCandidates ::
  (WithConnection :> es, IOE :> es) =>
  Int ->
  Eff es [MemoryMaintenanceCandidate]
listMemoryMaintenanceCandidates minimumEntries = do
  rows <-
    query
      "SELECT scope, scope_id, COALESCE(source_group_id, scope_id), count(*)::int \
      \ FROM memories \
      \ WHERE lifecycle = 'active' \
      \ GROUP BY scope, scope_id, COALESCE(source_group_id, scope_id) \
      \ HAVING count(*) >= ? AND max(updated_at) > now() - interval '49 hours'"
      (Only minimumEntries)
  pure [MemoryMaintenanceCandidate scope sid gid count | (scope, sid, gid, count) <- rows]

listMemoryMaintenanceEntries ::
  (WithConnection :> es, IOE :> es) =>
  MemoryNamespace ->
  Eff es [MemoryMaintenanceEntry]
listMemoryMaintenanceEntries ns = do
  let (scope, sid, gid) = namespaceParts ns
  query
    "SELECT memory.id, memory.version, memory.scope, memory.scope_id, \
    \       memory.content, memory.lifecycle, memory.category, memory.updated_at, \
    \       evidence.evidence_kind, evidence.source_conversation_id, \
    \       evidence.source_principal_id, evidence.source_message_id, \
    \       evidence.source_start_ingest_seq, evidence.source_end_ingest_seq, \
    \       evidence.source_episode_id, evidence.note, evidence.created_at \
    \ FROM memories AS memory \
    \ LEFT JOIN LATERAL ( \
    \   SELECT evidence_kind, source_conversation_id, source_principal_id, \
    \          source_message_id, source_start_ingest_seq, source_end_ingest_seq, \
    \          source_episode_id, note, created_at \
    \   FROM memory_evidence \
    \   WHERE memory_id = memory.id AND memory_version = memory.version \
    \   ORDER BY id DESC LIMIT 1 \
    \ ) AS evidence ON true \
    \ WHERE memory.scope = ? AND memory.scope_id = ? \
    \   AND (memory.scope = 'group' OR memory.source_group_id = ?) \
    \   AND memory.lifecycle IN ('active', 'permanent') \
    \ ORDER BY memory.updated_at, memory.id"
    (scope, sid, gid)

data EvidenceParts = EvidenceParts
  { evidenceKind :: !Text,
    evidenceConversation :: !(Maybe Int64),
    evidencePrincipal :: !(Maybe Int64),
    evidenceMessage :: !(Maybe Int64),
    evidenceStart :: !(Maybe Int64),
    evidenceEnd :: !(Maybe Int64),
    evidenceEpisode :: !(Maybe Int64),
    evidenceNote :: !(Maybe Text)
  }

evidenceParts :: MemoryEvidence -> EvidenceParts
evidenceParts = \case
  LegacyEvidence mScope note ->
    (emptyEvidence "legacy") {evidenceConversation = conversationStorageId <$> mScope, evidenceNote = Just note}
  MessageEvidence scope principal messageId ->
    (emptyEvidence "message")
      { evidenceConversation = Just (conversationStorageId scope),
        evidencePrincipal = principal,
        evidenceMessage = Just messageId
      }
  RangeEvidence scope start end ->
    (emptyEvidence "range")
      { evidenceConversation = Just (conversationStorageId scope),
        evidenceStart = Just start,
        evidenceEnd = Just end
      }
  EpisodeEvidence scope episodeId ->
    (emptyEvidence "episode")
      { evidenceConversation = Just (conversationStorageId scope),
        evidenceEpisode = Just episodeId
      }
  MaintenanceEvidence scope note ->
    (emptyEvidence "maintenance")
      { evidenceConversation = Just (conversationStorageId scope),
        evidenceNote = Just note
      }
  AdminEvidence mScope note ->
    (emptyEvidence "admin")
      { evidenceConversation = conversationStorageId <$> mScope,
        evidenceNote = Just note
      }

emptyEvidence :: Text -> EvidenceParts
emptyEvidence kind =
  EvidenceParts
    { evidenceKind = kind,
      evidenceConversation = Nothing,
      evidencePrincipal = Nothing,
      evidenceMessage = Nothing,
      evidenceStart = Nothing,
      evidenceEnd = Nothing,
      evidenceEpisode = Nothing,
      evidenceNote = Nothing
    }

evidenceActions :: EvidenceParts -> [PG.Action]
evidenceActions evidence =
  [ PG.toField evidence.evidenceKind,
    PG.toField evidence.evidenceConversation,
    PG.toField evidence.evidencePrincipal,
    PG.toField evidence.evidenceMessage,
    PG.toField evidence.evidenceStart,
    PG.toField evidence.evidenceEnd,
    PG.toField evidence.evidenceEpisode,
    PG.toField evidence.evidenceNote
  ]

createLifecycleAllowed :: MemoryActor -> MemoryLifecycle -> Bool
createLifecycleAllowed _ MemoryActive = True
createLifecycleAllowed actor MemoryPermanent = actorMayMutatePermanent actor
createLifecycleAllowed _ MemoryArchived = False
createLifecycleAllowed _ MemorySuperseded = False

evidenceAllowed :: MemoryActor -> Int64 -> MemoryEvidence -> Bool
evidenceAllowed actor expectedConversation evidence = case evidence of
  LegacyEvidence mScope _ ->
    actor.actorKind == ActorAdmin
      && maybe True ((== expectedConversation) . conversationStorageId) mScope
  AdminEvidence mScope _ ->
    actor.actorKind == ActorAdmin
      && (expectedConversation == 0 || maybe True ((== expectedConversation) . conversationStorageId) mScope)
  MessageEvidence scope _ _ -> matches scope
  RangeEvidence scope _ _ -> matches scope
  EpisodeEvidence scope _ -> matches scope
  MaintenanceEvidence scope _ -> matches scope
  where
    matches scope = conversationStorageId scope == expectedConversation

mutationResult :: [MemoryItem] -> MemoryMutationResult
mutationResult = \case
  item : _ -> MemoryMutationApplied item
  [] -> MemoryMutationRejected

expectOne :: (IOE :> es) => String -> [a] -> Eff es a
expectOne label = \case
  [item] -> pure item
  rows -> liftIO . throwIO . userError $ label <> ": expected one returned row, got " <> show (length rows)

storeInvariantFailure :: (IOE :> es) => String -> Eff es a
storeInvariantFailure = liftIO . throwIO . userError

-- Kept in one place so dynamic, code-controlled SQL fragments never involve
-- user text.  All values still travel as parameters.
fromStringQuery :: String -> Query
fromStringQuery = fromString
