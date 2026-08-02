module Max.ContextAdminSpec (spec) where

import Data.Aeson (Value, withObject, (.:))
import Data.Aeson.Types (Parser, parseEither)
import Data.Int (Int64)
import Data.Text (Text)
import Data.Time (UTCTime)
import Database.PostgreSQL.Simple (Only (..), execute)
import Effectful.PostgreSQL (query)
import Helpers (insertRawMessage, truncateAll, withDb)
import Max.Context (ContextDecision (..), ContextTrace (..), contextBudget)
import Max.ContextAdmin
import Max.ContextTraceStore (ContextPlanTraceRow (..), listContextPlanTraces, recordContextPlanTrace)
import Max.ConversationScope (ConversationScope, conversationScopeFor)
import Max.DB.Connection (DbPool, withConn)
import Max.DB.ConversationCursor (advanceCursor, historianCursor, loadCursor)
import Max.DB.History (MessageCursor (..))
import Max.MemoryStore
import Max.ModelCatalog (defaultContextLimits)
import OneBot.Types (GroupId (..))
import Test.Hspec

spec :: DbPool -> Spec
spec pool = before_ (truncateAll pool) $ describe "Max.ContextAdmin" $ do
  it "reports raw-tail lag and fails integrity when a cursor jumps over uncovered source" $ do
    insertRawMessage pool 1001 groupId memberId botId testTime Nothing "first"
    insertRawMessage pool 1002 groupId memberId botId testTime Nothing "second"

    initial <- withDb pool (loadContextStatus (Just groupId))
    parseCoverage initial `shouldBe` Right (0, 2, [])
    parseCutover initial `shouldBe` Right ("all_conversations", False, 0, 0, False)

    _ <- withDb pool (loadCursor scope historianCursor)
    withDb pool (advanceCursor scope historianCursor (MessageCursor 0) (MessageCursor 2))
      `shouldReturn` True
    jumped <- withDb pool (loadContextStatus (Just groupId))
    parseCoverage jumped
      `shouldBe` Right (2, 0, ["settled messages are not owned by an active compartment"])
    integrity <- withDb pool (runContextIntegrityCheck (Just groupId))
    parseIntegrity integrity `shouldBe` Right False

  it "detects a legacy extractor cursor as an old/new worker conflict" $ do
    withConn pool $ \conn -> do
      _ <-
        execute
          conn
          "INSERT INTO conversation_cursors (conversation_id, cursor_name, ingest_seq) VALUES (?, 'memory_extract', 0)"
          (Only groupId)
      pure ()
    conflicted <- withDb pool (loadContextStatus (Just groupId))
    parseCutover conflicted `shouldBe` Right ("all_conversations", True, 0, 1, True)

  it "persists body-free prompt decisions and returns their budget" $ do
    let budget = contextBudget defaultContextLimits False
        decisions = [ContextTrace "history.raw" 123 ContextIncluded "selected chronological raw transcript"]
    withDb pool $
      recordContextPlanTrace
        scope
        1001
        "tiered"
        "context-policy/test"
        (Just 3)
        (Just "high_water")
        budget
        456
        True
        decisions
    traces <- withDb pool (listContextPlanTraces (Just groupId) 10)
    map (\trace -> (trace.cptrHistoryMode, trace.cptrEstimatedPromptTokens, trace.cptrWithinBudget)) traces
      `shouldBe` [("tiered", 456, True)]

  it "invalidates only the requested conversation embedding projection" $ do
    insertRawMessage pool 1001 groupId memberId botId testTime Nothing "searchable message"
    insertRawMessage pool 2001 otherGroup memberId botId testTime Nothing "other message"
    withConn pool $ \conn -> do
      _ <-
        execute
          conn
          "UPDATE messages SET embedding = '[1,0]'::vector, embedding_model = 'test-model', \
          \ embedding_dimensions = 2, embedding_content_hash = encode(digest(convert_to(rendered_text, 'UTF8'), 'sha256'), 'hex'), \
          \ embedding_updated_at = now()"
          ()
      pure ()
    invalidated <- withDb pool $ invalidateEmbeddingsAdmin groupId ["message"]
    invalidated `shouldSatisfy` \case Right _ -> True; Left _ -> False
    rows <-
      withDb pool $
        query
          "SELECT group_id, embedding IS NULL FROM messages ORDER BY group_id"
          ()
    (rows :: [(Int64, Bool)]) `shouldBe` [(groupId, True), (otherGroup, False)]

  it "returns the complete memory version, evidence, and mutation history" $ do
    memory <-
      withDb pool $
        createMemory
          (MemoryActor ActorAdmin Nothing (Just "fixture"))
          (groupMemoryNamespace scope)
          MemoryDraft
            { draftContent = "the group uses tea",
              draftLifecycle = MemoryActive,
              draftCategory = Just GroupConvention,
              draftEvidence = AdminEvidence (Just scope) "fixture evidence"
            }
    detail <- withDb pool (fetchMemoryHistoryAdmin memory.memId)
    detail `shouldSatisfy` (/= Nothing)
    parseMemoryCounts (maybe (error "missing detail") id detail) `shouldBe` Right (1, 1, 1)

parseCoverage :: Value -> Either String (Int64, Int64, [Text])
parseCoverage = parseEither $ withObject "status" $ \root -> do
  conversations <- root .: "conversations" :: Parser [Value]
  case conversations of
    [conversation] -> withObject "conversation" parseOne conversation
    _ -> fail "expected one conversation"
  where
    parseOne objectValue =
      (,,)
        <$> objectValue .: "uncovered_settled_messages"
        <*> objectValue .: "live_tail_messages"
        <*> objectValue .: "issues"

parseIntegrity :: Value -> Either String Bool
parseIntegrity = parseEither (withObject "integrity" (.: "ok"))

parseCutover :: Value -> Either String (Text, Bool, Int64, Int64, Bool)
parseCutover = parseEither $ withObject "status" $ \root -> do
  cutover <- root .: "cutover"
  withObject
    "cutover"
    ( \objectValue ->
        (,,,,)
          <$> objectValue .: "reader_mode"
          <*> objectValue .: "legacy_extractor_running"
          <*> objectValue .: "legacy_session_anchor_columns"
          <*> objectValue .: "legacy_memory_cursor_rows"
          <*> objectValue .: "old_new_worker_conflict"
    )
    cutover

parseMemoryCounts :: Value -> Either String (Int, Int, Int)
parseMemoryCounts = parseEither $ withObject "memory detail" $ \detail -> do
  versions <- detail .: "versions" :: Parser [Value]
  evidence <- detail .: "evidence" :: Parser [Value]
  mutations <- detail .: "mutations" :: Parser [Value]
  pure (length versions, length evidence, length mutations)

scope :: ConversationScope
scope = conversationScopeFor (GroupId groupId)

groupId, otherGroup, memberId, botId :: Int64
groupId = 100
otherGroup = 101
memberId = 2001
botId = 1000

testTime :: UTCTime
testTime = read "2026-08-02 12:00:00 UTC"
