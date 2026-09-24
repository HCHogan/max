module Max.ContextReadSpec (spec) where

import Control.Monad (forM, forM_, void)
import Data.Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (parseEither)
import Data.Either (isLeft)
import Data.Foldable (toList)
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (addUTCTime, utc)
import Database.PostgreSQL.Simple (Only (..))
import Effectful.PostgreSQL (execute, query)
import Helpers (insertRawMessage, requireJust, testTime, truncateAll, withDb)
import Max.Context.Read
import Max.ConversationScope (conversationScopeFor, currentConversationRecall)
import Max.DB.Connection (DbPool)
import Max.DB.History (MessageCursor (..))
import Max.Effects.ConversationQuery qualified as Q
import Max.EpisodeStore
import Max.MemoryStore qualified as Memory
import Max.Recall (searchRecallFiltered)
import Max.Recall.Types
import OneBot.Types (GroupId (..))
import Test.Hspec

spec :: DbPool -> Spec
spec pool = before_ (truncateAll pool) $ describe "context_read navigation" $ do
  let scope = conversationScopeFor (GroupId 900)
      put mid body = insertRawMessage pool mid 900 1 99 testTime Nothing body
      readPage budget args = do
        request <- either (error . show) pure (parseEither (parseReadRequest utc) args)
        withDb pool (Q.runConversationQuery scope (Q.readContext budget request)) >>= either (error . T.unpack) pure
      refs = map (field "ref") . items

  it "reads exact messages and both neighbors; continuation pages stay chronological" $ do
    ids <- forM [1 .. 6] $ \n -> put n (T.pack (show n))
    page <- readPage 4096 (object ["ref" .= messageRef (ids !! 2), "before" .= (1 :: Int), "after" .= (1 :: Int), "limit" .= (3 :: Int)])
    refs page `shouldBe` map (String . messageRef) (take 3 (drop 1 ids))
    older <- readPage 4096 (field "prev" page)
    refs older `shouldBe` map (String . messageRef) (take 1 ids)
    newer <- readPage 4096 (field "next" page)
    refs newer `shouldBe` map (String . messageRef) (drop 4 ids)
    field "next" newer `shouldBe` Null
    field "prev" older `shouldBe` Null

  it "walks an exclusive date range without escaping it" $ do
    _ <- insertRawMessage pool 1 900 1 99 (addUTCTime (-10) testTime) Nothing "before"
    a <- put 2 "first"
    b <- insertRawMessage pool 3 900 1 99 (addUTCTime 1 testTime) Nothing "second"
    _ <- insertRawMessage pool 4 900 1 99 (addUTCTime 2 testTime) Nothing "outside"
    page <- readPage 4096 (object ["from" .= testTime, "until" .= addUTCTime 2 testTime, "limit" .= (1 :: Int)])
    refs page `shouldBe` [String (messageRef a)]
    next <- readPage 4096 (field "next" page)
    refs next `shouldBe` [String (messageRef b)]
    field "next" next `shouldBe` Null
    field "prev" page `shouldBe` Null

  it "reassembles a long body with no silent 400-character truncation" $ do
    let body = T.replicate 1200 "原文😀"
    mid <- put 1 body
    first <- readPage 512 (object ["ref" .= messageRef mid])
    let collect page = case items page of
          [item] -> case field "more" item of
            Null -> pure (textField "text" item)
            more -> (textField "text" item <>) <$> (readPage 512 more >>= collect)
          _ -> error "expected one body item"
    item <- case items first of [value] -> pure value; _ -> fail "expected one item"
    field "complete" item `shouldBe` Bool False
    collect first `shouldReturn` body
    void $ withDb pool (execute "UPDATE messages SET rendered_text='edited' WHERE canonical_message_id=?" (Only mid))
    let continuation = field "more" item
    request <- either error pure (parseEither (parseReadRequest utc) continuation)
    withDb pool (Q.runConversationQuery scope (Q.readContext 512 request)) >>= (`shouldSatisfy` isLeft)

  it "never widens scope via an ID or cursor" $ do
    mid <- put 1 "private to this group"
    _ <- put 2 "next"
    page <- readPage 4096 (object ["ref" .= messageRef mid])
    request <- either error pure (parseEither (parseReadRequest utc) (field "next" page))
    withDb pool (Q.runConversationQuery (conversationScopeFor (GroupId 901)) (Q.readContext 4096 request)) >>= (`shouldSatisfy` isLeft)
    direct <- either error pure (parseEither (parseReadRequest utc) (object ["ref" .= messageRef mid]))
    withDb pool (Q.runConversationQuery (conversationScopeFor (GroupId 901)) (Q.readContext 4096 direct)) >>= (`shouldSatisfy` isLeft)

  it "pages forwarded children in their own order and excludes them from the group timeline" $ do
    parent <- put 1 "forward container"
    children <- forM [1 .. 105 :: Int64] $ \n -> do
      child <- put (n + 1) (T.pack (show n))
      void $ withDb pool (execute "INSERT INTO message_relations(canonical_message_id,relation_kind,target_canonical_message_id,relation_position) VALUES(?,'contained_in',?,?)" (child, parent, n))
      pure child
    first <- readPage 32768 (object ["ref" .= ("forward:" <> T.pack (show parent)), "limit" .= (100 :: Int)])
    refs first `shouldBe` map (String . messageRef) (take 100 children)
    next <- readPage 32768 (field "next" first)
    refs next `shouldBe` map (String . messageRef) (drop 100 children)
    recent <- readPage 4096 (object [])
    refs recent `shouldBe` [String (messageRef parent)]

  it "uses an episode as an anchor, not a navigation fence" $ do
    a <- put 1 "before episode"
    b <- put 2 "episode source"
    [Only start, Only end] <- withDb pool (query "SELECT ingest_seq FROM messages WHERE group_id=900 ORDER BY ingest_seq" ())
    run <- withDb pool (prepareBackfillRun scope (MessageCursor start) (MessageCursor end) (CaptureRequest CaptureBackfill "test" "test/v1" 1)) >>= requireJust "capture"
    source <- withDb pool (loadCaptureSource run)
    let summary = CitedSummary "episode source" [b]
        capture = EpisodeCapture summary summary summary 0.8 0.9 Mixed []
    validated <- either (error . show) pure (validateEpisodeCapture run source capture)
    _ <- withDb pool (publishCaptureRun scope run "fixture" validated)
    [active] <- withDb pool (listActiveCompartments scope)
    c <- put 3 "after episode"
    page <- readPage 4096 (object ["ref" .= ("episode:" <> episodeHandleText active.activeExpandHandle), "limit" .= (2 :: Int)])
    refs page `shouldBe` map (String . messageRef) [b, c]
    map (field "in_episode") (items page) `shouldBe` [Bool True, Bool False]
    older <- readPage 4096 (field "prev" page)
    refs older `shouldBe` [String (messageRef a)]

  it "filters search candidates before truncating/ranking" $ do
    old <- insertRawMessage pool 1 900 1 99 (addUTCTime (-60) testTime) Nothing "needle"
    forM_ [2 .. 80] $ \n -> put n "needle"
    hits <- withDb pool (searchRecallFiltered (currentConversationRecall scope) (RecallFilter ["message"] Nothing (Just testTime) Nothing) "needle" Nothing 1)
    map (.rhMessageId) hits `shouldBe` [Just old]
    withDb pool (searchRecallFiltered (currentConversationRecall scope) (RecallFilter ["memory"] Nothing Nothing Nothing) "needle" Nothing 30) `shouldReturn` []

  it "expands scoped memory evidence back to original messages" $ do
    mid <- put 1 "I prefer green tea"
    mem <-
      withDb pool $
        Memory.createMemory
          (Memory.MemoryActor Memory.ActorAgentTool Nothing Nothing)
          (Memory.groupMemoryNamespace scope)
          (Memory.MemoryDraft "green tea preference" Memory.MemoryActive Nothing (Memory.MessageEvidence scope Nothing mid))
    page <- readPage 4096 (object ["ref" .= ("memory:" <> T.pack (show mem.memId.unMemoryId))])
    item <- case items page of [value] -> pure value; _ -> fail "expected memory"
    textField "text" item `shouldBe` "green tea preference"
    let evidence = case field "evidence" item of Array values -> toList values; _ -> []
    map (field "message") evidence `shouldBe` [object ["ref" .= messageRef mid]]
    dated <- either error pure (parseEither (parseReadRequest utc) (object ["ref" .= ("memory:" <> T.pack (show mem.memId.unMemoryId)), "from" .= ("2099-01-01" :: Text)]))
    withDb pool (Q.runConversationQuery scope (Q.readContext 4096 dated)) >>= (`shouldSatisfy` isLeft)

field :: Key -> Value -> Value
field key (Object fields) = KM.lookup key fields `orElse` Null
  where
    orElse (Just value) _ = value; orElse Nothing fallback = fallback
field _ _ = Null

items :: Value -> [Value]
items page = case field "items" page of Array rows -> toList rows; _ -> []

textField :: Key -> Value -> Text
textField key value = case field key value of String text -> text; _ -> error "expected text"
