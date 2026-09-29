module Max.LingoStoreSpec (spec) where

import Control.Monad (forM_, void)
import Control.Concurrent (threadDelay)
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Set qualified as Set
import Database.PostgreSQL.Simple (Only (..))
import Database.PostgreSQL.Simple.Types (PGArray (..))
import Effectful (IOE, liftIO)
import Effectful.Concurrent.Async (Concurrent, runConcurrent)
import Effectful.Log (Log)
import Effectful.PostgreSQL (WithConnection, execute, query)
import Helpers (insertMessageWithCanonicalId, testTime, truncateAll, withDb, withDbLog)
import Max.ConversationScope (ConversationScope, conversationScopeFor)
import Max.DB.Connection (DbPool)
import Max.DB.ConversationCursor (advanceCursor, historianCursor, lingoCursor, loadCursor)
import Max.DB.History (MessageCursor (..), latestMessageCursor)
import Max.Effects.Blob (Blob)
import Max.Effects.LLM (ChatMessage (..), ChatResponse (..), LLMInterpreter (..), runLLMWith)
import Max.Http.Failure (ResponseFailure (..), TransportFailure (..))
import Max.LLM.Failure (LLMFailure (..))
import Max.Lingo.Policy (ExpressionObservation (..), JargonObservation (..))
import Max.Lingo.Types
import Max.LingoLearner (LingoStep (..), inferDueJargon, learnConversationOnce, lingoBatchLines, skipFailingBatch)
import Max.LingoStore
import OneBot.Types (GroupId (..))
import Test.Hspec

spec :: DbPool -> Spec
spec pool = before_ (truncateAll pool) $ describe "Max.LingoStore and learner" $ do
  it "learns a settled range, keeping member habits and dropping Max's own" $ do
    seedConversation pool 13
    settleThrough pool Nothing
    calls <- newIORef (0 :: Int)
    let model = LLMInterpreter $ \_ _ messages _ _ -> do
          liftIO (atomicModifyIORef' calls (\n -> (n + 1, ())))
          -- Source numbering follows the transcript, bot lines included.
          case messages of
            [MsgSystem _, MsgUser body] | "[3] Max（你自己）：我是鲨鱼" `T.isInfixOf` body -> pure ()
            _ -> error ("unexpected learner input: " <> show messages)
          pure . Right . ContentResp $
            "{\"expressions\": [{\"situation\": \"讽刺地赞同\", \"style\": \"用 对对对\", \"source_id\": 1}, \
            \{\"situation\": \"自称\", \"style\": \"说 我是鲨鱼\", \"source_id\": 3}], \
            \\"jargon\": [{\"term\": \"典\", \"source_id\": 2}]}"
    step <- learnOnce pool model 1
    step `shouldBe` LingoLearned 1 1
    readIORef calls `shouldReturn` 1
    end <- withDb pool (latestMessageCursor scope)
    withDb pool (loadCursor scope lingoCursor) `shouldReturn` end
    expressions <- withDb pool (listExpressionCandidates scope 10)
    map (\e -> (e.leStyle, e.leHits, e.leExample)) expressions `shouldBe` [("用 对对对", 1, "对对对，你说的都对")]
    terms <- withDb pool (query "SELECT term, hits, cardinality(speakers) FROM lingo_jargon" ())
    (terms :: [(Text, Int, Int)]) `shouldBe` [("典", 1, 1)]

  it "waits for enough settled member talk and never reads past the Historian" $ do
    seedConversation pool 13
    settleThrough pool (Just 105)
    calls <- newIORef (0 :: Int)
    let model = LLMInterpreter $ \_ _ _ _ _ -> do
          liftIO (atomicModifyIORef' calls (\n -> (n + 1, ())))
          pure (Right (ContentResp "{}"))
    step <- learnOnce pool model 1
    step `shouldBe` LingoWaiting
    readIORef calls `shouldReturn` 0
    withDb pool (loadCursor scope lingoCursor) `shouldReturn` MessageCursor 0

  it "learns consecutive batches concurrently and commits them in order" $ do
    seedConversation pool (2 * lingoBatchLines + 30)
    settleThrough pool Nothing
    inFlight <- newIORef (0 :: Int)
    peak <- newIORef (0 :: Int)
    let model = LLMInterpreter $ \_ _ _ _ _ -> liftIO $ do
          atomicModifyIORef' inFlight (\n -> (n + 1, ())) >> readIORef inFlight >>= \n -> atomicModifyIORef' peak (\p -> (max p n, ()))
          threadDelay 200_000
          atomicModifyIORef' inFlight (\n -> (n - 1, ()))
          pure (Right (ContentResp "{\"expressions\": [{\"situation\": \"讽刺地赞同\", \"style\": \"用 对对对\", \"source_id\": 1}]}"))
    learnOnce pool model 3 `shouldReturn` LingoLearned 3 0
    readIORef peak `shouldReturn` 3
    end <- withDb pool (latestMessageCursor scope)
    withDb pool (loadCursor scope lingoCursor) `shouldReturn` end
    -- Every batch opens with a member line, so each batch observed the style
    -- once and the three merged in order.
    hits <- withDb pool (query "SELECT hits, example_text FROM lingo_expressions" ())
    (hits :: [(Int, Text)]) `shouldBe` [(3, "第 121 句闲聊")]

  it "commits only the batches before the first failure" $ do
    seedConversation pool (2 * lingoBatchLines + 30)
    settleThrough pool Nothing
    let model = LLMInterpreter $ \_ _ messages _ _ -> pure $ case messages of
          [_, MsgUser body] | "第 70 句闲聊" `T.isInfixOf` body -> Left (LLMResponseFailure (ResponseTransport ResponseTimeoutFailure))
          _ -> Right (ContentResp "{}")
    learnOnce pool model 3 `shouldReturn` LingoLearned 0 0
    firstBatchEnd <- withDb pool $ do
      rows <- query "SELECT ingest_seq FROM messages WHERE canonical_message_id = ?" (Only (100 + fromIntegral lingoBatchLines :: Int64))
      pure [MessageCursor seq' | Only seq' <- rows]
    withDb pool (loadCursor scope lingoCursor) >>= \cursor -> [cursor] `shouldBe` firstBatchEnd
    -- The failed batch is next; with nothing committed the pass reports it.
    learnOnce pool model 1 >>= (`shouldSatisfy` \case LingoFailed _ -> True; _ -> False)

  it "moves past a settled range that holds nothing of this conversation" $ do
    insertMessageWithCanonicalId pool 201 600 11 botId testTime (Just "阿飞") "别的群在聊天"
    elsewhere <- withDb pool (latestMessageCursor (conversationScopeFor (GroupId 600)))
    withDb pool (loadCursor scope historianCursor) `shouldReturn` MessageCursor 0
    void (withDb pool (advanceCursor scope historianCursor (MessageCursor 0) elsewhere))
    let model = LLMInterpreter $ \_ _ _ _ _ -> error "nothing to learn"
    learnOnce pool model 1 `shouldReturn` LingoLearned 0 0
    withDb pool (loadCursor scope lingoCursor) `shouldReturn` elsewhere

  it "skips exactly one failing batch without learning from it" $ do
    seedConversation pool (lingoBatchLines + 5)
    settleThrough pool Nothing
    start <- withDb pool (loadCursor scope lingoCursor)
    withDb pool (skipFailingBatch scope start) `shouldReturn` True
    skippedTo <- withDb pool (loadCursor scope lingoCursor)
    end <- withDb pool (latestMessageCursor scope)
    skippedTo `shouldSatisfy` (\cursor -> cursor > start && cursor < end)
    counts <- withDb pool (query "SELECT (SELECT count(*) FROM lingo_expressions), (SELECT count(*) FROM lingo_jargon)" ())
    (counts :: [(Int, Int)]) `shouldBe` [(0, 0)]

  it "merges repeated observations and refuses a stale cursor" $ do
    seedConversation pool 3
    let expression = ExpressionObservation "讽刺地赞同" "用 对对对" "用对对对" 101 "对对对"
        term principal message = JargonObservation "典" "典" message principal "典" ("line " <> T.pack (show message))
    (alice, bob) <- memberPrincipals pool
    withDb pool (loadCursor scope lingoCursor) `shouldReturn` MessageCursor 0
    withDb pool (recordLingoBatch scope (MessageCursor 0) (MessageCursor 1) [expression] [term alice 101]) `shouldReturn` True
    withDb pool (recordLingoBatch scope (MessageCursor 1) (MessageCursor 2) [expression] [term bob 102]) `shouldReturn` True
    withDb pool (recordLingoBatch scope (MessageCursor 1) (MessageCursor 3) [expression] [term alice 103]) `shouldReturn` False
    withDb pool (loadCursor scope lingoCursor) `shouldReturn` MessageCursor 2
    hits <- withDb pool (query "SELECT hits FROM lingo_expressions" ())
    (hits :: [Only Int]) `shouldBe` [Only 2]
    terms <- withDb pool (query "SELECT hits, cardinality(speakers), contexts FROM lingo_jargon" ())
    map (\(termHits, speakers, PGArray contexts) -> (termHits, speakers, contexts)) (terms :: [(Int, Int, PGArray Text)])
      `shouldBe` [(2, 2, ["line 101", "line 102"])]

  it "hides an expression whose example its author took back" $ do
    seedConversation pool 3
    void $ withDb pool (recordLingoBatch scope (MessageCursor 0) (MessageCursor 1) [ExpressionObservation "讽刺地赞同" "用 对对对" "用对对对" 101 "对对对"] [])
    withDb pool (redactedAmong [101, 102]) `shouldReturn` Set.empty
    void . withDb pool $
      execute
        "INSERT INTO message_relations (canonical_message_id, relation_kind, target_canonical_message_id) VALUES (?, 'redacts', ?)"
        (102 :: Int64, 101 :: Int64)
    withDb pool (redactedAmong [101, 102]) `shouldReturn` Set.fromList [101]
    withDb pool (listExpressionCandidates scope 10) `shouldReturn` []

  it "infers a group-specific meaning against the context-free reading" $ do
    seedConversation pool 1
    void . withDb pool $
      execute
        "INSERT INTO lingo_jargon (conversation_id, term, term_key, hits, speakers, contexts, example_message_id, example_text) \
        \ VALUES (?, '炸鸡', '炸鸡', 4, '{11,12}', '{\"阿飞：又炸鸡了\"}', 101, '又炸鸡了')"
        (Only conversationId)
    let model = LLMInterpreter $ \_ _ messages _ _ -> pure . Right . ContentResp $ case messages of
          [MsgUser prompt]
            | "不看任何上下文" `T.isInfixOf` prompt -> "{\"meaning\": \"一种油炸食物\"}"
            | "一般被理解为：一种油炸食物" `T.isInfixOf` prompt && "阿飞：又炸鸡了" `T.isInfixOf` prompt ->
                "{\"meaning\": \"把芯片或板子烧坏\", \"group_specific\": true, \"no_info\": false}"
          _ -> "{}"
    withDbLog pool (runLLMWith model (inferDueJargon "lingo-test" 60 scope)) `shouldReturn` 1
    withDb pool (listKnownJargon scope 10) `shouldReturn` [LingoJargon "炸鸡" "把芯片或板子烧坏" 4]
    -- Inferred at this count: not due again until the next threshold.
    withDbLog pool (runLLMWith model (inferDueJargon "lingo-test" 60 scope)) `shouldReturn` 0

  it "retries a term after a provider failure but not after an unreadable answer" $ do
    seedConversation pool 1
    void . withDb pool $
      execute
        "INSERT INTO lingo_jargon (conversation_id, term, term_key, hits, speakers, contexts, example_message_id, example_text) \
        \ VALUES (?, '炸鸡', '炸鸡', 4, '{11,12}', '{\"阿飞：又炸鸡了\"}', 101, '又炸鸡了')"
        (Only conversationId)
    let outage = LLMInterpreter $ \_ _ _ _ _ -> pure (Left (LLMResponseFailure (ResponseTransport ResponseTimeoutFailure)))
        garbled = LLMInterpreter $ \_ _ _ _ _ -> pure (Right (ContentResp "不知道"))
        inferred = withDb pool (query "SELECT inferred_hits, meaning IS NULL, group_specific FROM lingo_jargon" ())
    withDbLog pool (runLLMWith outage (inferDueJargon "lingo-test" 60 scope)) `shouldReturn` 0
    (inferred :: IO [(Int, Bool, Bool)]) `shouldReturn` [(0, True, False)]
    withDbLog pool (runLLMWith garbled (inferDueJargon "lingo-test" 60 scope)) `shouldReturn` 1
    (inferred :: IO [(Int, Bool, Bool)]) `shouldReturn` [(4, True, False)]
  where
    groupId = 500 :: Int64
    conversationId = groupId
    scope :: ConversationScope
    scope = conversationScopeFor (GroupId groupId)

-- | One learner pass over the test conversation with @parallel@ batches.
learnOnce :: DbPool -> LLMInterpreter '[Concurrent, Blob, WithConnection, Log, IOE] -> Int -> IO LingoStep
learnOnce pool model batches =
  withDbLog pool (runConcurrent (runLLMWith model (learnConversationOnce "lingo-test" 60 batches (conversationScopeFor (GroupId 500)))))

-- | Canonical ids 101.. with two members; the third line is Max's own.
seedConversation :: DbPool -> Int -> IO ()
seedConversation pool count =
  forM_ (zip [1 .. count] [101 :: Int64 ..]) $ \(n, canonical) ->
    let (user, body) = case n of
          1 -> (11, "对对对，你说的都对")
          2 -> (12, "又开始了，典")
          3 -> (botId, "我是鲨鱼")
          _ -> (if even n then 11 else 12, "第 " <> T.pack (show n) <> " 句闲聊")
     in insertMessageWithCanonicalId pool canonical 500 user botId testTime (Just (nameOf user)) body
  where
    nameOf :: Int64 -> Text
    nameOf user
      | user == botId = "Max"
      | user == 11 = "阿飞"
      | otherwise = "老张"

botId :: Int64
botId = 999

-- | Move the Historian cursor to a canonical message (or the ledger end).
settleThrough :: DbPool -> Maybe Int64 -> IO ()
settleThrough pool through = withDb pool $ do
  let scope = conversationScopeFor (GroupId 500)
  start <- loadCursor scope historianCursor
  end <- case through of
    Nothing -> latestMessageCursor scope
    Just canonical -> do
      rows <- query "SELECT ingest_seq FROM messages WHERE canonical_message_id = ?" (Only canonical)
      case rows of
        [Only seq'] -> pure (MessageCursor seq')
        _ -> error "settleThrough: missing message"
  void (advanceCursor scope historianCursor start end)

memberPrincipals :: DbPool -> IO (Int64, Int64)
memberPrincipals pool = do
  rows <- withDb pool (query "SELECT author_principal_id FROM messages WHERE canonical_message_id IN (101, 102) ORDER BY canonical_message_id" ())
  case rows of
    [Only alice, Only bob] -> pure (alice, bob)
    _ -> error "memberPrincipals: seed the conversation first"
