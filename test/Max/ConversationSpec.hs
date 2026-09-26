module Max.ConversationSpec (spec) where

import Control.Concurrent.Async (concurrently, wait, withAsync)
import Control.Concurrent.STM qualified as STM
import Control.Monad (forM_, replicateM_)
import Data.Int (Int64)
import Data.Maybe (isNothing)
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian)
import Max.Conversation
import Max.LLM.Types (ChatMessage (MsgUser))
import Max.Node.Events qualified as Events
import Max.Node.Executor qualified as Node
import Max.Node.Render (renderEvents)
import Max.Platform.Types (PrincipalId (..))
import Max.Task.FrontendInput (FrontendInputView (..))
import Max.Turn.Types (AgentTurnId (..))
import OneBot.Types (GroupId (..))
import System.Timeout (timeout)
import Test.Hspec

spec :: Spec
spec = describe "Max.Conversation" $ do
  it "routes steering to the newest open owner even when that owner yielded" $ do
    queue <- newConversations
    first <- admit queue (request 1)
    Just actor <- actorFor first
    future <- STM.newEmptyTMVarIO
    withAsync (Node.await actor True STM.retry (STM.readTMVar future)) $ \waiting -> do
      next <- admit queue ((request 2) {principal = PrincipalId 99})
      timeout 1000000 (awaitTurn next) `shouldReturn` Just True
      feedback <- admit queue (steering 3)
      text <- observeFrontend queue (AgentTurnId 1)
      text `shouldSatisfy` T.isInfixOf "correction"
      awaitTurn feedback `shouldReturn` False
      release queue next
      STM.atomically (STM.putTMVar future ())
      wait waiting `shouldReturn` Just ()

  it "serializes independent inputs and lets other conversations run" $ do
    queue <- newConversations
    first <- admit queue (request 1)
    next <- admit queue (request 2)
    other <- admit queue ((request 3) {group = GroupId 2})
    awaitTurn first `shouldReturn` True
    awaitTurn other `shouldReturn` True
    withAsync (awaitTurn next) $ \waiting -> do
      (isNothing <$> timeout 20000 (wait waiting)) `shouldReturn` True
      observeFrontend queue (AgentTurnId 1) `shouldReturn` ""
      release queue first
      wait waiting `shouldReturn` True

  it "delivers only explicit owner feedback, once, with canonical provenance" $ do
    queue <- newConversations
    _ <- admit queue (request 1)
    feedback <- admit queue (steering 2)
    outsider <- admit queue ((steering 3) {principal = PrincipalId 99})
    separate <- admit queue ((steering 4) {feedback = Nothing})
    text <- observeFrontend queue (AgentTurnId 1)
    forM_ ["\"message_id\":2", "\"author_principal_id\":7", "\"reply_to\":1", "Alice", "correction"] $ \field ->
      text `shouldSatisfy` T.isInfixOf field
    awaitTurn feedback `shouldReturn` False
    observeFrontend queue (AgentTurnId 1) `shouldReturn` ""
    withAsync (awaitTurn outsider) $ \waiting -> (isNothing <$> timeout 20000 (wait waiting)) `shouldReturn` True
    withAsync (awaitTurn separate) $ \waiting -> (isNothing <$> timeout 20000 (wait waiting)) `shouldReturn` True

  it "does not mix conversations or feed a message older than the trigger" $ do
    queue <- newConversations
    first <- admit queue (request 2)
    older <- admit queue (steering 1)
    other <- admit queue ((steering 3) {group = GroupId 9})
    observeFrontend queue (AgentTurnId 2) `shouldReturn` ""
    awaitTurn other `shouldReturn` True
    release queue first
    awaitTurn older `shouldReturn` True

  it "orders feedback by canonical ingestion order, with a 200 item observation bound" $ do
    queue <- newConversations
    _ <- admit queue (request 1)
    forM_ (reverse [2 .. 203]) $ \n -> admit queue (steering n)
    first <- observeFrontend queue (AgentTurnId 1)
    T.count "\"message_id\":" first `shouldBe` 200
    map (T.isInfixOf "\"message_id\":2,") (take 1 (drop 1 (T.lines first))) `shouldBe` [True]
    second <- observeFrontend queue (AgentTurnId 1)
    T.count "\"message_id\":" second `shouldBe` 2
    observeFrontend queue (AgentTurnId 1) `shouldReturn` ""

  it "atomically either accepts feedback before finishing or routes it to a new task" $ do
    replicateM_ 100 $ do
      queue <- newConversations
      first <- admit queue (request 1)
      Just target <- STM.atomically (eventsFor queue (AgentTurnId 1))
      (finished, next) <- concurrently (STM.atomically (Events.tryFinish target)) (admit queue (steering 2))
      if finished
        then do
          release queue first
          awaitTurn next `shouldReturn` True
        else do
          awaitTurn next `shouldReturn` False
          observeFrontend queue (AgentTurnId 1) >>= (`shouldSatisfy` T.isInfixOf "correction")
          STM.atomically (Events.tryFinish target) `shouldReturn` True

  it "cancels a waiting ticket without releasing the current owner" $ do
    queue <- newConversations
    first <- admit queue (request 1)
    cancelled <- admit queue (request 2)
    next <- admit queue (request 3)
    release queue cancelled
    withAsync (awaitTurn next) $ \waiting -> do
      (isNothing <$> timeout 20000 (wait waiting)) `shouldReturn` True
      release queue first
      wait waiting `shouldReturn` True
      release queue first
      awaitTurn next `shouldReturn` True

  it "runs queued foreground work before notices, without feeding notice turns" $ do
    queue <- newConversations
    first <- admit queue (request 1)
    notice <- admit queue ((request 2) {notice = True, acceptsFeedback = False})
    next <- admit queue (request 3)
    release queue first
    awaitTurn next `shouldReturn` True
    withAsync (awaitTurn notice) $ \waiting -> do
      (isNothing <$> timeout 20000 (wait waiting)) `shouldReturn` True
      release queue next
      wait waiting `shouldReturn` True
    feedback <- admit queue (steering 4)
    observeFrontend queue (AgentTurnId 2) `shouldReturn` ""
    release queue notice
    awaitTurn feedback `shouldReturn` True

  it "keeps observed feedback bounded until its runtime releases the slot" $ do
    queue <- newConversations
    _ <- admit queue (request 1)
    firstFeedback : _ <- mapM (admit queue . steering) [2 .. 256]
    _ <- observeFrontend queue (AgentTurnId 1)
    (isNothing <$> enqueue queue (request 257)) `shouldReturn` True
    release queue firstFeedback
    _ <- admit queue (request 257)
    pure ()

  it "bounds queued turns per conversation and across the process, reclaiming cancelled slots" $ do
    queue <- newConversations
    first <- admit queue (request 1)
    forM_ [2 .. 256] $ \n -> admit queue (request n)
    (isNothing <$> enqueue queue (request 257)) `shouldReturn` True
    forM_ [2 .. 4] $ \g ->
      forM_ [1 .. 256] $ \n -> admit queue ((request (g * 1000 + n)) {group = GroupId g})
    (isNothing <$> enqueue queue ((request 5001) {group = GroupId 5})) `shouldReturn` True
    release queue first
    _ <- admit queue ((request 5001) {group = GroupId 5})
    pure ()

admit :: Conversations -> TurnInput -> IO TaskHandle
admit queue input = enqueue queue input >>= maybe (expectationFailure "queue full" >> fail "queue full") pure

request :: Int64 -> TurnInput
request n = TurnInput (GroupId 1) (AgentTurnId n) (PrincipalId 7) (Just n) Nothing True False

steering :: Int64 -> TurnInput
steering n = (request n) {feedback = Just (FrontendInputView n "steering" 7 (Just "Alice") (UTCTime (fromGregorian 2026 9 19) 0) (Just 1) "correction")}

observeFrontend :: Conversations -> AgentTurnId -> IO T.Text
observeFrontend queue turn = STM.atomically $ do
  target <- eventsFor queue turn
  events <- maybe (pure []) Events.observe target
  pure (T.intercalate "\n" [text | MsgUser text <- renderEvents events])
