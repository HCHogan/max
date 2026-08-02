module Max.MemoryStoreSpec (spec) where

import Control.Exception (SomeException)
import Data.Int (Int64)
import Data.Text (Text)
import Database.PostgreSQL.Simple (Only (..), execute)
import Effectful.PostgreSQL (query)
import Helpers (truncateAll, withDb)
import Max.ConversationScope (conversationScopeFor, currentConversationRecall)
import Max.DB.Connection (DbPool, withConn)
import Max.Embedding (EmbeddingRecord (..))
import Max.MemoryStore
import OneBot.Types (GroupId (..), UserId (..), privateChatGroupId)
import Test.Hspec

spec :: DbPool -> Spec
spec pool = before_ (truncateAll pool) $
  describe "Max.MemoryStore" $ do
    let scopeA = conversationScopeFor (GroupId 100)
        scopeB = conversationScopeFor (GroupId 200)
        nsA = userMemoryNamespace scopeA 3001
        nsB = userMemoryNamespace scopeB 3001
        evidenceA = MessageEvidence scopeA (Just 3001) 9001

    it "atomically creates a version, evidence link, and audit event" $ do
      item <- withDb pool $ createMemory extractor nsA (activeDraft evidenceA "first fact")
      item.memVersion `shouldBe` MemoryVersion 1
      item.memLifecycle `shouldBe` "active"

      versions <-
        withDb pool $
          query
            "SELECT version, content, lifecycle FROM memory_versions WHERE memory_id = ?"
            (Only item.memId)
      (versions :: [(MemoryVersion, Text, Text)])
        `shouldBe` [(MemoryVersion 1, "first fact", "active")]

      evidence <-
        withDb pool $
          query
            "SELECT evidence_kind, source_conversation_id, source_principal_id, source_message_id \
            \ FROM memory_evidence WHERE memory_id = ?"
            (Only item.memId)
      (evidence :: [(Text, Maybe Int64, Maybe Int64, Maybe Int64)])
        `shouldBe` [("message", Just 100, Just 3001, Just 9001)]

      audit <-
        withDb pool $
          query
            "SELECT from_version, to_version, operation, actor_kind, conversation_id \
            \ FROM memory_mutations WHERE memory_id = ?"
            (Only item.memId)
      (audit :: [(Maybe MemoryVersion, MemoryVersion, Text, Text, Maybe Int64)])
        `shouldBe` [(Nothing, MemoryVersion 1, "create", "extractor", Just 100)]

    it "uses version CAS and preserves append-only content history" $ do
      item <- withDb pool $ createMemory extractor nsA (activeDraft evidenceA "v1")
      applied <-
        withDb pool $
          updateMemory
            extractor
            nsA
            item.memId
            (ExpectedVersion item.memVersion)
            (MemoryUpdate "v2" (RangeEvidence scopeA 10 20))
      updated <- case applied of
        MemoryMutationApplied value -> pure value
        MemoryMutationRejected -> expectationFailure "first CAS unexpectedly rejected" >> pure item
      updated.memVersion `shouldBe` MemoryVersion 2

      stale <-
        withDb pool $
          updateMemory
            extractor
            nsA
            item.memId
            (ExpectedVersion item.memVersion)
            (MemoryUpdate "lost update" (RangeEvidence scopeA 10 20))
      stale `shouldBe` MemoryMutationRejected

      versions <-
        withDb pool $
          query
            "SELECT version, content FROM memory_versions WHERE memory_id = ? ORDER BY version"
            (Only item.memId)
      (versions :: [(MemoryVersion, Text)])
        `shouldBe` [(MemoryVersion 1, "v1"), (MemoryVersion 2, "v2")]

    it "archives instead of deleting and removes archived rows from recall" $ do
      item <- withDb pool $ createMemory extractor nsA (activeDraft evidenceA "temporary")
      result <-
        withDb pool $
          archiveMemory extractor nsA item.memId (ExpectedVersion item.memVersion)
      archived <- case result of
        MemoryMutationApplied value -> pure value
        MemoryMutationRejected -> expectationFailure "archive unexpectedly rejected" >> pure item
      archived.memLifecycle `shouldBe` "archived"
      withDb pool (listMemories nsA) `shouldReturn` []
      visible <- withDb pool $ fetchVisibleMemory (currentConversationRecall scopeA) item.memId
      visible `shouldBe` Nothing
      admin <- withDb pool $ fetchMemoryAdmin item.memId
      fmap (.memLifecycle) admin `shouldBe` Just "archived"

    it "protects permanent memory from automatic maintenance" $ do
      item <-
        withDb pool $
          createMemory
            toolActor
            nsA
            (activeDraft evidenceA "explicitly remembered") {draftLifecycle = MemoryPermanent}
      automaticUpdate <-
        withDb pool $
          updateMemory
            dreamer
            nsA
            item.memId
            (ExpectedVersion item.memVersion)
            (MemoryUpdate "dream rewrite" (MaintenanceEvidence scopeA "nightly"))
      automaticArchive <-
        withDb pool $
          archiveMemory dreamer nsA item.memId (ExpectedVersion item.memVersion)
      automaticUpdate `shouldBe` MemoryMutationRejected
      automaticArchive `shouldBe` MemoryMutationRejected

      explicitArchive <-
        withDb pool $
          archiveMemory toolActor nsA item.memId (ExpectedVersion item.memVersion)
      explicitArchive `shouldSatisfy` \case MemoryMutationApplied _ -> True; _ -> False

    it "atomically supersedes within one namespace and rejects foreign targets" $ do
      old <- withDb pool $ createMemory extractor nsA (activeDraft evidenceA "old fact")
      replacement <- withDb pool $ createMemory extractor nsA (activeDraft evidenceA "new fact")
      foreignItem <-
        withDb pool $
          createMemory
            extractor
            nsB
            (activeDraft (MessageEvidence scopeB (Just 3001) 9002) "foreign fact")
      denied <-
        withDb pool $
          supersedeMemory extractor nsA old.memId (ExpectedVersion old.memVersion) foreignItem.memId
      denied `shouldBe` MemoryMutationRejected
      result <-
        withDb pool $
          supersedeMemory extractor nsA old.memId (ExpectedVersion old.memVersion) replacement.memId
      superseded <- case result of
        MemoryMutationApplied value -> pure value
        MemoryMutationRejected -> expectationFailure "supersede unexpectedly rejected" >> pure old
      superseded.memLifecycle `shouldBe` "superseded"
      map (.memId) <$> withDb pool (listMemories nsA) `shouldReturn` [replacement.memId]

      target <-
        withDb pool $
          query
            "SELECT superseded_by FROM memories WHERE id = ?"
            (Only old.memId)
      (target :: [Only MemoryId]) `shouldBe` [Only replacement.memId]

    it "rejects evidence whose origin does not match the authorized namespace" $ do
      let foreignEvidence = MessageEvidence scopeB (Just 3001) 9002
      withDb pool (createMemory extractor nsA (activeDraft foreignEvidence "bad provenance"))
        `shouldThrow` (\(_ :: SomeException) -> True)
      item <- withDb pool $ createMemory extractor nsA (activeDraft evidenceA "good provenance")
      result <-
        withDb pool $
          updateMemory
            extractor
            nsA
            item.memId
            (ExpectedVersion item.memVersion)
            (MemoryUpdate "bad update" foreignEvidence)
      result `shouldBe` MemoryMutationRejected

    it "keeps the same subject isolated by origin conversation" $ do
      itemA <- withDb pool $ createMemory extractor nsA (activeDraft evidenceA "from A")
      _ <-
        withDb pool $
          createMemory
            extractor
            nsB
            (activeDraft (MessageEvidence scopeB (Just 3001) 9002) "from B")
      map (.memId) <$> withDb pool (listMemories nsA) `shouldReturn` [itemA.memId]
      denied <-
        withDb pool $
          updateVisibleMemory
            extractor
            (currentConversationRecall scopeB)
            itemA.memId
            (ExpectedVersion itemA.memVersion)
            (MemoryUpdate "stolen" (MessageEvidence scopeB (Just 3001) 9002))
      denied `shouldBe` MemoryMutationRejected

    it "does not project group memory into a direct chat" $ do
      _ <- withDb pool $ createMemory extractor (groupMemoryNamespace scopeA) (activeDraft evidenceA "group only")
      let direct = conversationScopeFor (privateChatGroupId (UserId 3001))
      withDb pool (listMemories (groupMemoryNamespace direct)) `shouldReturn` []

    it "partitions direct chats from one another" $ do
      let directA = conversationScopeFor (privateChatGroupId (UserId 3001))
          directB = conversationScopeFor (privateChatGroupId (UserId 3002))
          directNsA = userMemoryNamespace directA 3001
          directNsB = userMemoryNamespace directB 3001
      item <-
        withDb pool $
          createMemory
            extractor
            directNsA
            (activeDraft (MessageEvidence directA (Just 3001) 8001) "private")
      map (.memId) <$> withDb pool (listMemories directNsA) `shouldReturn` [item.memId]
      withDb pool (listMemories directNsB) `shouldReturn` []

    it "CAS-stores embedding provenance and invalidates it on content update" $ do
      item <- withDb pool $ createMemory extractor nsA (activeDraft evidenceA "old content")
      stale <-
        withDb pool $
          markMemoryEmbedded
            nsA
            item.memId
            (ExpectedVersion (MemoryVersion 99))
            "old content"
            threeDimensionalEmbedding
      stored <-
        withDb pool $
          markMemoryEmbedded
            nsA
            item.memId
            (ExpectedVersion item.memVersion)
            "old content"
            threeDimensionalEmbedding
      stale `shouldBe` False
      stored `shouldBe` True

      result <-
        withDb pool $
          updateMemory
            extractor
            nsA
            item.memId
            (ExpectedVersion item.memVersion)
            (MemoryUpdate "new content" (RangeEvidence scopeA 20 30))
      result `shouldSatisfy` \case MemoryMutationApplied _ -> True; _ -> False
      rows <-
        withDb pool $
          query
            "SELECT embedding IS NULL, embedding_model IS NULL, \
            \       embedding_dimensions IS NULL, embedding_content_hash IS NULL, \
            \       embedding_updated_at IS NULL \
            \ FROM memories WHERE id = ?"
            (Only item.memId)
      (rows :: [(Bool, Bool, Bool, Bool, Bool)])
        `shouldBe` [(True, True, True, True, True)]

    it "queues model changes and isolates mixed dimensions" $ do
      first <- withDb pool $ createMemory extractor nsA (activeDraft evidenceA "three dimensions")
      second <- withDb pool $ createMemory extractor nsA (activeDraft evidenceA "two dimensions")
      _ <-
        withDb pool $
          markMemoryEmbedded nsA first.memId (ExpectedVersion first.memVersion) first.memContent threeDimensionalEmbedding
      _ <-
        withDb pool $
          markMemoryEmbedded nsA second.memId (ExpectedVersion second.memVersion) second.memContent twoDimensionalEmbedding

      pendingCurrent <- withDb pool $ listPendingMemoryEmbeddings "embedding-v1" 10
      pendingNext <- withDb pool $ listPendingMemoryEmbeddings "embedding-v2" 10
      pendingCurrent `shouldBe` []
      map (.pendingMemoryId) pendingNext `shouldMatchList` [first.memId, second.memId]

      nearest <- withDb pool $ findNearestMemory nsA twoDimensionalEmbedding
      fmap fst nearest `shouldBe` Just second.memId

    it "makes version, evidence, and audit ledgers immutable" $ do
      item <- withDb pool $ createMemory extractor nsA (activeDraft evidenceA "immutable")
      withConn
        pool
        (\conn -> execute conn "UPDATE memory_versions SET content = 'tampered' WHERE memory_id = ?" (Only item.memId))
        `shouldThrow` (\(_ :: SomeException) -> True)
      withConn
        pool
        (\conn -> execute conn "DELETE FROM memory_evidence WHERE memory_id = ?" (Only item.memId))
        `shouldThrow` (\(_ :: SomeException) -> True)
      withConn
        pool
        (\conn -> execute conn "DELETE FROM memory_mutations WHERE memory_id = ?" (Only item.memId))
        `shouldThrow` (\(_ :: SomeException) -> True)

activeDraft :: MemoryEvidence -> Text -> MemoryDraft
activeDraft evidence content =
  MemoryDraft
    { draftContent = content,
      draftLifecycle = MemoryActive,
      draftCategory = Nothing,
      draftEvidence = evidence
    }

extractor :: MemoryActor
extractor = MemoryActor ActorExtractor Nothing (Just "integration test")

dreamer :: MemoryActor
dreamer = MemoryActor ActorDreamer Nothing (Just "integration test")

toolActor :: MemoryActor
toolActor = MemoryActor ActorAgentTool (Just 3001) (Just "explicit request")

threeDimensionalEmbedding :: EmbeddingRecord
threeDimensionalEmbedding =
  EmbeddingRecord
    { erModelId = "embedding-v1",
      erDimensions = 3,
      erContentHash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      erVector = "[1,2,3]"
    }

twoDimensionalEmbedding :: EmbeddingRecord
twoDimensionalEmbedding =
  EmbeddingRecord
    { erModelId = "embedding-v1",
      erDimensions = 2,
      erContentHash = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      erVector = "[1,2]"
    }
