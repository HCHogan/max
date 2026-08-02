module Max.DB.MemorySpec (spec) where

import Data.Int (Int64)
import Data.Text (Text)
import Database.PostgreSQL.Simple (Only (..))
import Effectful.PostgreSQL (query)
import Helpers (truncateAll, withDb)
import Max.ConversationScope (conversationScopeFor)
import Max.DB.Connection (DbPool)
import Max.DB.Memory
  ( MemoryItem (..),
    deleteVisibleMemory,
    groupMemoryNamespace,
    insertMemory,
    listMemories,
    markMemoryEmbedded,
    updateVisibleMemory,
    userMemoryNamespace,
  )
import Max.Embedding (EmbeddingRecord (..))
import OneBot.Types (GroupId (..), UserId (..), privateChatGroupId)
import Test.Hspec

groupA, groupB, userA :: Int64
groupA = 100
groupB = 200
userA = 3001

spec :: DbPool -> Spec
spec pool = before_ (truncateAll pool) $
  describe "Max.DB.Memory conversation isolation" $ do
    let scopeA = conversationScopeFor (GroupId groupA)
        scopeB = conversationScopeFor (GroupId groupB)
        groupNsA = groupMemoryNamespace scopeA
        groupNsB = groupMemoryNamespace scopeB
        userNsA = userMemoryNamespace scopeA userA
        userNsB = userMemoryNamespace scopeB userA

    it "partitions group memories by the authorized conversation" $ do
      midA <- withDb pool $ insertMemory groupNsA "group A fact"
      _ <- withDb pool $ insertMemory groupNsB "group B secret"
      rows <- withDb pool $ listMemories groupNsA
      map (.memId) rows `shouldBe` [midA]
      map (.memContent) rows `shouldBe` ["group A fact"]

    it "partitions the same user by the conversation where it was learned" $ do
      midA <- withDb pool $ insertMemory userNsA "user fact from A"
      _ <- withDb pool $ insertMemory userNsB "user secret from B"
      rows <- withDb pool $ listMemories userNsA
      map (.memId) rows `shouldBe` [midA]
      map (.memContent) rows `shouldBe` ["user fact from A"]

    it "does not project group memory into a direct chat by default" $ do
      _ <- withDb pool $ insertMemory groupNsA "group-only fact"
      let dmScope = conversationScopeFor (privateChatGroupId (UserId userA))
      rows <- withDb pool $ listMemories (groupMemoryNamespace dmScope)
      rows `shouldSatisfy` null

    it "partitions direct chats from each other" $ do
      let dmA = conversationScopeFor (privateChatGroupId (UserId userA))
          dmB = conversationScopeFor (privateChatGroupId (UserId (userA + 1)))
          dmANs = userMemoryNamespace dmA userA
          dmBNs = userMemoryNamespace dmB userA
      mid <- withDb pool $ insertMemory dmANs "private fact"
      visible <- withDb pool $ listMemories dmANs
      hidden <- withDb pool $ listMemories dmBNs
      map (.memId) visible `shouldBe` [mid]
      hidden `shouldSatisfy` null

    it "rejects cross-conversation update and delete by global id" $ do
      midB <- withDb pool $ insertMemory userNsB "secret"
      updated <- withDb pool $ updateVisibleMemory scopeA midB "stolen"
      deleted <- withDb pool $ deleteVisibleMemory scopeA midB
      updated `shouldBe` False
      deleted `shouldBe` False
      rows <- withDb pool $ listMemories userNsB
      map (.memContent) rows `shouldBe` ["secret"]

    it "atomically invalidates the embedding when visible content changes" $ do
      mid <- withDb pool $ insertMemory userNsA "old content"
      embedded <- withDb pool $ markMemoryEmbedded userNsA mid "old content" testEmbedding
      embedded `shouldBe` True
      updated <- withDb pool $ updateVisibleMemory scopeA mid "new content"
      updated `shouldBe` True
      rows <-
        withDb pool $
          query
            "SELECT content, embedding IS NULL, embedding_model IS NULL, \
            \       embedding_dimensions IS NULL, embedding_content_hash IS NULL, \
            \       embedding_updated_at IS NULL \
            \ FROM memories WHERE id = ?"
            [mid]
      (rows :: [(Text, Bool, Bool, Bool, Bool, Bool)])
        `shouldBe` [("new content", True, True, True, True, True)]

    it "stores embedding provenance only when expected content still matches" $ do
      mid <- withDb pool $ insertMemory userNsA "current content"
      stale <- withDb pool $ markMemoryEmbedded userNsA mid "old content" testEmbedding
      stale `shouldBe` False
      stored <- withDb pool $ markMemoryEmbedded userNsA mid "current content" testEmbedding
      stored `shouldBe` True
      rows <-
        withDb pool $
          query
            "SELECT embedding_model, embedding_dimensions, embedding_content_hash, \
            \       vector_dims(embedding) \
            \ FROM memories WHERE id = ?"
            [mid]
      (rows :: [(Text, Int, Text, Int)])
        `shouldBe` [("embedding-v1", 3, replicateText 64 "a", 3)]

    it "queues model changes and never compares incompatible dimensions" $ do
      first <- withDb pool $ insertMemory userNsA "three dimensions"
      second <- withDb pool $ insertMemory userNsA "two dimensions"
      _ <- withDb pool $ markMemoryEmbedded userNsA first "three dimensions" testEmbedding
      _ <- withDb pool $ markMemoryEmbedded userNsA second "two dimensions" twoDimensionalEmbedding

      pendingCurrent <-
        withDb pool $
          query
            "SELECT id FROM memories \
            \ WHERE embedding IS NULL OR embedding_model IS DISTINCT FROM ? ORDER BY id"
            ["embedding-v1" :: Text]
      pendingNext <-
        withDb pool $
          query
            "SELECT id FROM memories \
            \ WHERE embedding IS NULL OR embedding_model IS DISTINCT FROM ? ORDER BY id"
            ["embedding-v2" :: Text]
      (pendingCurrent :: [Only Int64]) `shouldBe` []
      pendingNext `shouldBe` [Only first, Only second]

      compatible <-
        withDb pool $
          query
            "WITH candidates AS MATERIALIZED ( \
            \  SELECT id, embedding FROM memories \
            \  WHERE embedding_model = ? AND embedding_dimensions = ? \
            \) \
            \ SELECT id FROM candidates ORDER BY embedding <=> ?::vector"
            ("embedding-v1" :: Text, 2 :: Int, "[1,2]" :: Text)
      (compatible :: [Only Int64]) `shouldBe` [Only second]

testEmbedding :: EmbeddingRecord
testEmbedding =
  EmbeddingRecord
    { erModelId = "embedding-v1",
      erDimensions = 3,
      erContentHash = replicateText 64 "a",
      erVector = "[1,2,3]"
    }

twoDimensionalEmbedding :: EmbeddingRecord
twoDimensionalEmbedding =
  EmbeddingRecord
    { erModelId = "embedding-v1",
      erDimensions = 2,
      erContentHash = replicateText 64 "b",
      erVector = "[1,2]"
    }

replicateText :: Int -> Text -> Text
replicateText n = mconcat . replicate n
