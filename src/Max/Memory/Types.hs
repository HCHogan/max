-- | Semantic memory vocabulary and SQL identity/row codecs. This module has
-- no connection, query, execution or mutation capability.
module Max.Memory.Types
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
    scopeText,
    parseScope,
    lifecycleText,
    categoryText,
    parseCategory,
    actorText,
    actorMayMutatePermanent,
    groupMemoryNamespace,
    userMemoryNamespace,
    memoryNamespace,
    namespaceParts,
    subjectNamespace,
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Int (Int64)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Time (UTCTime)
import Database.PostgreSQL.Simple.FromField (FromField)
import Database.PostgreSQL.Simple.FromRow (FromRow (..), field)
import Database.PostgreSQL.Simple.ToField (ToField)
import Max.ConversationScope (ConversationScope, conversationStorageId)
import Max.Memory.Policy (MemorySubject (..))

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

-- | A person's memories inside one conversation.  The subject is a
-- @principal_id@ (ADR 004): a memory is about a human, and which account they
-- happened to speak from is transport.  The column held a compatibility user
-- id until migration 066, which is why it is named 'scope_id' and not
-- 'principal_id'.
userMemoryNamespace :: ConversationScope -> Int64 -> MemoryNamespace
userMemoryNamespace scope principal = MemoryNamespace ScopeUser principal scope

memoryNamespace :: ConversationScope -> MemoryScope -> Int64 -> MemoryNamespace
memoryNamespace scope ScopeGroup _ = groupMemoryNamespace scope
memoryNamespace scope ScopeUser uid = userMemoryNamespace scope uid

namespaceParts :: MemoryNamespace -> (Text, Int64, Int64)
namespaceParts ns =
  ( scopeText ns.namespaceScope,
    ns.namespaceSubjectId,
    conversationStorageId ns.namespaceConversation
  )

subjectNamespace :: ConversationScope -> Int64 -> MemorySubject -> MemoryNamespace
subjectNamespace scope _ ConversationMemory = groupMemoryNamespace scope
subjectNamespace scope principal (PersonMemory requested) = userMemoryNamespace scope (fromMaybe principal requested)
