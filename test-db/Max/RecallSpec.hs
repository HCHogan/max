module Max.RecallSpec (spec) where

import Data.Aeson (encode)
import Data.ByteString.Lazy qualified as LBS
import Data.Int (Int64)
import Data.List (nub, sort)
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime)
import Database.PostgreSQL.Simple (Only (..), execute_)
import Effectful.PostgreSQL (query)
import Helpers (insertRawMessage, truncateAll, withDb)
import Max.ConversationScope (ConversationScope, conversationScopeFor, currentConversationRecall)
import Max.DB.Connection (DbPool, withConn)
import Max.DB.History (MessageCursor (..))
import Max.Embedding (EmbeddingRecord (..))
import Max.EpisodeStore
import Max.MemoryStore
import Max.Recall
import OneBot.Types (GroupId (..))
import Test.Hspec

groupA, groupB, member, botId :: Int64
groupA = 700
groupB = 701
member = 2001
botId = 1000

scopeA, scopeB :: ConversationScope
scopeA = conversationScopeFor (GroupId groupA)
scopeB = conversationScopeFor (GroupId groupB)

spec :: DbPool -> Spec
spec pool = before_ (truncateAll pool) $ describe "Max.Recall" $ do
  it "searches all five scoped corpora with quotas and message-level deduplication" $ do
    seedRecallFixture pool
    hits <- withDb pool $ searchRecall (currentConversationRecall scopeA) "tea" Nothing 10

    sort (map (.rhSource) hits)
      `shouldBe` ["caption", "episode", "memory", "message", "pin"]
    length (nub (map (.rhDedupKey) hits)) `shouldBe` length hits
    [message | hit <- hits, hit.rhSource == "message", Just message <- [hit.rhMessageId]]
      `shouldBe` [1001]
    [message | hit <- hits, hit.rhSource == "pin", Just message <- [hit.rhMessageId]]
      `shouldBe` [1002]
    [message | hit <- hits, hit.rhSource == "caption", Just message <- [hit.rhMessageId]]
      `shouldBe` [1003]
    hits `shouldSatisfy` any (\hit -> hit.rhSource == "episode" && hit.rhEpisodeHandle /= Nothing)

    crossScope <- withDb pool $ searchRecall (currentConversationRecall scopeB) "tea" Nothing 30
    crossScope `shouldBe` []

  it "fuses only compatible semantic candidates and remains scoped" $ do
    seedRecallFixture pool
    installCompatibleVectors pool
    let queryEmbedding = EmbeddingRecord "recall-test" 2 (replicateText 64 "f") "[1,0]"
    hits <- withDb pool $ searchRecall (currentConversationRecall scopeA) "no lexical overlap" (Just queryEmbedding) 20

    hits `shouldSatisfy` any (\hit -> hit.rhSource == "memory" && hit.rhSemanticScore == Just 1)
    hits `shouldSatisfy` any (\hit -> hit.rhSource == "episode" && hit.rhSemanticScore == Just 1)
    hits `shouldSatisfy` any (\hit -> hit.rhSource `elem` ["message", "pin"] && hit.rhSemanticScore == Just 1)

    crossScope <- withDb pool $ searchRecall (currentConversationRecall scopeB) "no lexical overlap" (Just queryEmbedding) 30
    crossScope `shouldBe` []

seedRecallFixture :: DbPool -> IO ()
seedRecallFixture pool = do
  insertRawMessage pool 1001 groupA member botId testTime Nothing "tea raw message"
  insertRawMessage pool 1002 groupA member botId testTime Nothing "tea pinned message"
  insertRawMessage pool 1003 groupA member botId testTime Nothing "photo only"
  _ <-
    withDb pool $
      createMemory
        (MemoryActor ActorAdmin Nothing (Just "recall fixture"))
        (groupMemoryNamespace scopeA)
        MemoryDraft
          { draftContent = "tea standalone memory",
            draftLifecycle = MemoryPermanent,
            draftCategory = Just GroupConvention,
            draftEvidence = AdminEvidence (Just scopeA) "recall fixture"
          }
  withConn pool $ \conn -> do
    _ <- execute_ conn "INSERT INTO sessions (group_id, pinned) VALUES (700, '[1002]'::jsonb)"
    _ <-
      execute_
        conn
        "INSERT INTO images (sha256, mime_type, bytes_size, local_path, description) \
        \ VALUES ('tea-image', 'image/png', 1, 'tea.png', 'tea caption')"
    _ <- execute_ conn "INSERT INTO message_images (message_id, sha256, seg_index) VALUES (1003, 'tea-image', 0)"
    pure ()

  end <- latestCursor pool
  run <-
    withDb pool (enqueueCaptureRun scopeA (MessageCursor 0) end request)
      >>= requireJust "capture run"
  lease <- withDb pool (claimCaptureRun "recall-test" 60) >>= requireJust "capture lease"
  source <- withDb pool $ loadCaptureSource run
  let capture =
        EpisodeCapture
          { captureSummaryP1 = CitedSummary "tea episode full" [1001, 1002, 1003],
            captureSummaryP2 = CitedSummary "tea episode compact" [1001, 1003],
            captureSummaryP3 = CitedSummary "tea episode anchor" [1003],
            captureImportance = 0.8,
            captureConfidence = 0.9,
            captureEpisodeKind = Mixed,
            captureMemoryProposals = [ProposalAdd "group" Nothing "tea memory" (Just "group_convention") [1001]]
          }
  validated <- case validateEpisodeCapture run source capture of
    Right value -> pure value
    Left errors -> expectationFailure (show errors) >> error "invalid recall capture"
  withDb pool (recordCaptureGenerated lease (captureJson capture) capture []) `shouldReturn` True
  _ <- withDb pool $ publishCaptureRun scopeA lease validated
  pure ()

installCompatibleVectors :: DbPool -> IO ()
installCompatibleVectors pool = withConn pool $ \conn -> do
  _ <-
    execute_
      conn
      "UPDATE messages SET embedding = '[1,0]'::vector, embedding_model = 'recall-test', \
      \ embedding_dimensions = 2, embedding_content_hash = repeat('a', 64), embedding_updated_at = now() \
      \ WHERE group_id = 700"
  _ <-
    execute_
      conn
      "UPDATE memories SET embedding = '[1,0]'::vector, embedding_model = 'recall-test', \
      \ embedding_dimensions = 2, embedding_content_hash = repeat('b', 64), embedding_updated_at = now() \
      \ WHERE source_group_id = 700"
  _ <-
    execute_
      conn
      "UPDATE conversation_compartments SET embedding = '[1,0]'::vector, embedding_model = 'recall-test', \
      \ embedding_dimensions = 2, embedding_content_hash = repeat('c', 64), embedding_updated_at = now() \
      \ WHERE conversation_id = 700"
  pure ()

latestCursor :: DbPool -> IO MessageCursor
latestCursor pool = do
  rows <- withDb pool $ query "SELECT max(ingest_seq) FROM messages WHERE group_id = ?" (Only groupA)
  case rows :: [Only (Maybe Int64)] of
    Only (Just cursor) : _ -> pure (MessageCursor cursor)
    _ -> expectationFailure "expected latest recall cursor" >> pure (MessageCursor 0)

request :: CaptureRequest
request =
  CaptureRequest
    { requestReason = CaptureIdle,
      requestHistorianProfile = "historian-test",
      requestPromptVersion = "historian/v1",
      requestSchemaVersion = 1
    }

captureJson :: EpisodeCapture -> Text
captureJson = TE.decodeUtf8 . LBS.toStrict . encode

requireJust :: String -> Maybe a -> IO a
requireJust label = \case
  Just value -> pure value
  Nothing -> expectationFailure ("missing " <> label) >> error ("missing " <> label)

replicateText :: Int -> Text -> Text
replicateText count = mconcat . replicate count

testTime :: UTCTime
testTime = read "2026-08-02 12:00:00 UTC"
