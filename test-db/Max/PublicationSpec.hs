module Max.PublicationSpec (spec) where

import Control.Concurrent.STM
import Control.Exception (try)
import Data.IORef
import Data.Int (Int64)
import Data.Text qualified as T
import Database.PostgreSQL.Simple (Only (..))
import Effectful (liftIO)
import Effectful.PostgreSQL (execute, query)
import Helpers (insertRawMessage, testTime, truncateAll, withDb, withDbLog)
import Max.AgentEvent
import Max.AgentOutput (AgentOutputContext (..), handleAgentEvent)
import Max.ConversationScope (conversationScopeFor)
import Max.DB.AgentTurn (startAgentTurn)
import Max.DB.Connection (DbPool)
import Max.DB.History (HistoryItem (..), fetchMessageWithCursorInScope)
import Max.Effects.Outbound
import Max.IR
import Max.Jobs (newJobs)
import Max.MessageKind (MessageKind (KindChat))
import Max.Platform.Types
import Max.Reply.Caption (captionBody)
import Max.ReplySend
import Max.Tasks
import Max.Turn.Types (nextTurnOutputLink)
import OneBot.Types (GroupId (..), UserId (..))
import Test.Hspec

spec :: DbPool -> Spec
spec pool = before_ (truncateAll pool) $ describe "canonical publication boundaries" $ do
  it "revokes output before signalling cancellation, retaining an already published prefix" $ do
    source <- insertRawMessage pool 100 900 123 9 testTime (Just "Alice") "source"
    [Only principal] <- withDb pool $ query "SELECT author_principal_id FROM messages WHERE canonical_message_id=?" (Only source)
    durable <- withDb pool (startAgentTurn (GroupId 900) (CanonicalMessageId source) (PrincipalId principal))
    registry <- newTaskRegistry
    jobs <- newJobs registry
    turn <- beginDurableTurnRuntime registry durable (GroupId 900) (UserId 123) (Just (CanonicalMessageId source))
    Just output <- pure (turnRuntimeOutputContext turn)
    let publish = do
          link <- nextTurnOutputLink output
          withDbLog pool $
            runOutbound registry jobs $
              sendRecorded
                (OutboundRequest KindChat (GroupId 900) (Body [NText "prefix"]) Nothing DeliverConversation (Just link) Nothing)
    first <- publish
    wasPublished first `shouldBe` True
    -- The signal is deliberately ignored: the publication gate must revoke first.
    _ <- activateTurnRuntime turn "streaming" (pure ())
    cancelTask registry (turnRuntimeTaskId turn) `shouldReturn` True
    publish `shouldReturn` PublicationFailed "turn publication was cancelled or its runtime ended"
    finishTurnRuntime registry turn
    publish `shouldReturn` PublicationFailed "turn publication was cancelled or its runtime ended"
    rows <- withDb pool $ query "SELECT count(*) FROM messages WHERE agent_turn_id IS NOT NULL" ()
    rows `shouldBe` [Only (1 :: Int64)]

  it "loads feedback from canonical history with scope, author, reply and ingestion order intact" $ do
    first <- insertRawMessage pool 100 900 123 9 testTime (Just "Alice") "source"
    second <- insertRawMessage pool 101 900 456 9 testTime (Just "Bob") "!feedback correction"
    _ <- withDb pool $ execute "UPDATE messages SET reply_to_canonical_message_id=? WHERE canonical_message_id=?" (first, second)
    Just (firstOrder, firstHistory) <- withDb pool (fetchMessageWithCursorInScope (conversationScopeFor (GroupId 900)) first)
    Just (secondOrder, history) <- withDb pool (fetchMessageWithCursorInScope (conversationScopeFor (GroupId 900)) second)
    secondOrder `shouldSatisfy` (> firstOrder)
    history.renderedText `shouldBe` "!feedback correction"
    history.senderNickname `shouldBe` Just "Bob"
    history.authorPrincipalId `shouldNotBe` firstHistory.authorPrincipalId
    history.replyTo `shouldBe` Just first
    history.receivedAt `shouldBe` testTime
    outside <- withDb pool (fetchMessageWithCursorInScope (conversationScopeFor (GroupId 901)) second)
    fmap fst outside `shouldBe` Nothing

  it "never acknowledges a failed stream publication or spends its budget" $ do
    budget <- newTVarIO freshBudget
    result <-
      try $
        withDbLog pool $
          runOutboundWith (const (pure (PublicationFailed "injected"))) $
            handleAgentEvent
              (AgentOutputContext target (CanonicalMessageId 1) False budget)
              (AgentFinalStreamText "first paragraph\n\n")
    case result of
      Left (ReplyPublicationException err) -> err `shouldBe` "injected"
      Right _ -> expectationFailure "publication failure was acknowledged or swallowed"
    readTVarIO budget `shouldReturn` freshBudget

  it "retains the committed prefix and stops before publishing a later suffix" $ do
    calls <- newIORef (0 :: Int)
    result <-
      withDbLog pool
        $ runOutboundWith
          ( \_ -> do
              index <- liftIO (atomicModifyIORef' calls (\i -> (i + 1, i)))
              pure $ if index == 0 then Published (CanonicalMessageId 10) else PublicationFailed "second failed"
          )
        $ sendAndPersistReply target freshBudget "first\n\nsecond\n\nthird"
    result.committed `shouldBe` [CanonicalMessageId 10]
    result.failure `shouldBe` Just "second failed"
    result.budget.sbChunksLeft `shouldBe` freshBudget.sbChunksLeft - 1
    readIORef calls `shouldReturn` 2

  it "resolves caption mentions and scoped replies through the shared canonical resolver" $ do
    source <- insertRawMessage pool 100 900 123 9 testTime (Just "Alice") "source"
    [Only principal] <- withDb pool $ query "SELECT author_principal_id FROM messages WHERE canonical_message_id=?" (Only source)
    let caption = "[reply#" <> T.pack (show source) <> "] [mention#" <> T.pack (show (principal :: Int64)) <> ": Alice] hello"
    (reply, body) <- withDbLog pool (captionBody qqAdvertisedCaps (GroupId 900) (Just caption))
    reply `shouldBe` Just (CanonicalMessageId source)
    length [() | NMention {} <- body.nodes] `shouldBe` 1
    (foreignReply, _) <- withDbLog pool (captionBody qqAdvertisedCaps (GroupId 901) (Just caption))
    foreignReply `shouldBe` Nothing

  it "keeps reply-only captions and folds layout without leaking placeholders" $ do
    source <- insertRawMessage pool 100 900 123 9 testTime (Just "Alice") "source"
    withDbLog pool (captionBody qqAdvertisedCaps (GroupId 900) (Just ("[reply#" <> T.pack (show source) <> "]")))
      `shouldReturn` (Just (CanonicalMessageId source), Body [])
    withDbLog pool (captionBody qqAdvertisedCaps (GroupId 900) (Just "hello [split] world"))
      `shouldReturn` (Nothing, Body [NText "hello\nworld", NText "\n"])
    withDbLog pool (captionBody qqAdvertisedCaps (GroupId 900) Nothing)
      `shouldReturn` (Nothing, Body [])
  where
    target = ReplyTarget (GroupId 900) [] Nothing False False False False False Nothing
