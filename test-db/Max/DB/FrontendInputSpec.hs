module Max.DB.FrontendInputSpec (spec) where

import Control.Concurrent.Async (concurrently)
import Control.Monad (void)
import Data.Aeson (object)
import Data.Int (Int64)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (getCurrentTime)
import Database.PostgreSQL.Simple.Types (Only (..))
import Effectful.PostgreSQL (execute, query)
import Helpers (truncateAll, withDb)
import Max.DB.AgentTurn
import Max.DB.Connection (DbPool)
import Max.DB.Task (admitTaskReceipt)
import Max.DB.Task.Frontend
import Max.DB.Task.FrontendInput (deferRequest, pendingRequest, readInputs)
import Max.DB.TaskSpec (draft, seed)
import Max.Platform.Store (DispatchClaim (..), DispatchCompletion (..), OutboundDraft (..), claimDispatch, completeDispatch, enqueueOutbound, startDispatch)
import Max.Platform.Types (CanonicalMessageId (..))
import Max.Task.Admission (AdmissionError (..))
import Max.Task.Types (TaskProfile (Research))
import Max.Turn.Types
import OneBot.Types (GroupId (..))
import Test.Hspec

spec :: DbPool -> Spec
spec pool = before_ (truncateAll pool) $ describe "frontend steering" $ do
  it "transfers a same-principal request and terminates its source in one commit" $ do
    (front, _, _) <- seed pool 900 1
    withDb pool (claimFrontend front) `shouldReturn` True
    (incoming, message, _) <- seed pool 900 1
    withDb pool (admitFrontend incoming (Just FeedbackInput)) `shouldReturn` FrontendInputQueued
    requests <- withDb pool $ query "SELECT turn_id,disposition FROM conversation_requests WHERE message_id=?" (Only message.unCanonicalMessageId)
    requests `shouldBe` [(front.atrTurnId, "pending" :: Text)]
    state <- withDb pool $ query "SELECT status FROM agent_turns WHERE turn_id=?" (Only incoming.atrTurnId)
    state `shouldBe` [Only ("aborted" :: Text)]
    dispatch <- withDb pool $ query "SELECT status FROM message_dispatches WHERE canonical_message_id=?" (Only message.unCanonicalMessageId)
    dispatch `shouldBe` [Only ("completed" :: Text)]

  it "does not inject an unmentioned message from another principal or a separately requested frontend" $ do
    (front, _, _) <- seed pool 900 1
    withDb pool (claimFrontend front) `shouldReturn` True
    (other, _, _) <- seed pool 900 2
    (separate, _, _) <- seed pool 900 1
    withDb pool (admitFrontend other (Just FeedbackInput)) `shouldReturn` FrontendBusy
    withDb pool (admitFrontend other (Just MessageInput)) `shouldReturn` FrontendBusy
    withDb pool (admitFrontend separate Nothing) `shouldReturn` FrontendBusy
    withDb pool (readInputs front.atrTurnId) `shouldReturn` ""

  it "keeps a mention in another conversation on its own frontend" $ do
    (front, _, _) <- seed pool 900 1
    withDb pool (claimFrontend front) `shouldReturn` True
    (other, _, _) <- seed pool 901 2
    withDb pool (admitFrontend other (Just MentionInput)) `shouldReturn` FrontendClaimed
    withDb pool (readInputs front.atrTurnId) `shouldReturn` ""

  it "retains ingress order, reply provenance and canonical text without grouping kinds" $ do
    (front, trigger, _) <- seed pool 900 1
    withDb pool (claimFrontend front) `shouldReturn` True
    (first, firstMessage, _) <- seed pool 900 1
    (second, secondMessage, _) <- seed pool 900 1
    void $ withDb pool $ execute "UPDATE messages SET rendered_text='first input' WHERE canonical_message_id=?" (Only firstMessage.unCanonicalMessageId)
    void $ withDb pool $ execute "UPDATE messages SET rendered_text='second input',reply_to_canonical_message_id=? WHERE canonical_message_id=?" (trigger.unCanonicalMessageId, secondMessage.unCanonicalMessageId)
    withDb pool (admitFrontend second (Just FeedbackInput)) `shouldReturn` FrontendInputQueued
    withDb pool (admitFrontend first (Just FeedbackInput)) `shouldReturn` FrontendInputQueued
    body <- withDb pool (readInputs front.atrTurnId)
    let entries = filter (T.isPrefixOf "{") (T.lines body)
    case entries of
      [firstEntry, secondEntry] -> do
        firstEntry `shouldSatisfy` T.isInfixOf "first input"
        firstEntry `shouldSatisfy` T.isInfixOf "\"kind\":\"steering\""
        secondEntry `shouldSatisfy` T.isInfixOf "second input"
        secondEntry `shouldSatisfy` T.isInfixOf "\"kind\":\"steering\""
      _ -> expectationFailure (show entries)
    withDb pool (readInputs front.atrTurnId) `shouldReturn` ""
    dispositions pool front `shouldReturn` ["pending", "pending", "pending"]

  it "deduplicates concurrent source turns for one canonical input" $ do
    (front, _, _) <- seed pool 900 1
    withDb pool (claimFrontend front) `shouldReturn` True
    (incoming, message, actor) <- seed pool 900 1
    duplicate <- withDb pool (startAgentTurn (GroupId 900) message actor)
    (left, right) <- concurrently (withDb pool (admitFrontend incoming (Just FeedbackInput))) (withDb pool (admitFrontend duplicate (Just FeedbackInput)))
    (left, right) `shouldBe` (FrontendInputQueued, FrontendInputQueued)
    count <- withDb pool $ query "SELECT count(*) FROM frontend_inputs WHERE message_id=?" (Only message.unCanonicalMessageId)
    count `shouldBe` [Only (1 :: Int64)]

  it "does not count debug output as a request reply" $ do
    (front, _, _) <- seed pool 900 1
    withDb pool (claimFrontend front) `shouldReturn` True
    void $ withDb pool (enqueueOutbound ((draft front) {transcriptKind = "debug"}))
    withDb pool (finishAgentTurn front TurnSucceeded 1 Nothing)
    dispositions pool front `shouldReturn` ["failed"]

  it "returns observed feedback to dispatch when reply publication fails" $ do
    (front, _, _) <- seed pool 900 1
    withDb pool (claimFrontend front) `shouldReturn` True
    (incoming, _, _) <- seed pool 900 1
    withDb pool (admitFrontend incoming (Just FeedbackInput)) `shouldReturn` FrontendInputQueued
    _ <- withDb pool (readInputs front.atrTurnId)
    withDb pool (finishAgentTurn front TurnFailed 1 (Just "publication failed"))
    dispositions pool front `shouldReturn` ["failed", "pending"]

  it "retains eligibility for a deferred intent trigger without an active dispatch owner" $ do
    (front, _, _) <- seed pool 900 1
    withDb pool (claimFrontend front) `shouldReturn` True
    (incoming, message, _) <- seed pool 900 1
    withDb pool (admitFrontend incoming (Just MessageInput)) `shouldReturn` FrontendBusy
    now <- getCurrentTime
    withDb pool (deferRequest incoming.atrTurnId now)
    withDb pool (finishAgentTurn incoming TurnAborted 0 Nothing)
    withDb pool (pendingRequest message.unCanonicalMessageId) `shouldReturn` True
    state <- withDb pool $ query "SELECT status FROM message_dispatches WHERE canonical_message_id=?" (Only message.unCanonicalMessageId)
    state `shouldBe` [Only ("deferred" :: Text)]

  it "fences the old dispatch finalizer after an unserved input returns to the queue" $ do
    (front, _, _) <- seed pool 900 1
    withDb pool (claimFrontend front) `shouldReturn` True
    (incoming, message, _) <- seed pool 900 1
    -- The ledger fixture deliberately suppresses dispatch; opt this input in
    -- before exercising the production reservation/claim handoff.
    void $ withDb pool $ execute "UPDATE message_dispatches SET status='pending' WHERE canonical_message_id=?" (Only message.unCanonicalMessageId)
    Just claim <- withDb pool (claimDispatch "original" message 120)
    withDb pool (startDispatch "original" message claim.attemptCount 120) `shouldReturn` True
    withDb pool (admitFrontend incoming (Just FeedbackInput)) `shouldReturn` FrontendInputQueued
    duplicateClaim <- withDb pool (claimDispatch "duplicate" message 120)
    fmap (.canonicalMessageId) duplicateClaim `shouldBe` Nothing
    withDb pool (finishAgentTurn front TurnFailed 1 Nothing)
    Just retryClaim <- withDb pool (claimDispatch "retry" message 120)
    withDb pool (startDispatch "retry" message retryClaim.attemptCount 120) `shouldReturn` True
    withDb pool (completeDispatch "original" message claim.attemptCount DispatchCompleted) `shouldReturn` False
    state <- withDb pool $ query "SELECT status,lease_owner FROM message_dispatches WHERE canonical_message_id=?" (Only message.unCanonicalMessageId)
    state `shouldBe` [("claimed" :: Text, Just ("retry" :: Text))]

  it "cancels assigned inputs without resurrecting their dispatches" $ do
    (front, _, _) <- seed pool 900 1
    withDb pool (claimFrontend front) `shouldReturn` True
    (incoming, message, _) <- seed pool 900 1
    withDb pool (admitFrontend incoming (Just FeedbackInput)) `shouldReturn` FrontendInputQueued
    withDb pool (finishAgentTurn front TurnCancelled 1 (Just "kill"))
    dispositions pool front `shouldReturn` ["cancelled", "cancelled"]
    state <- withDb pool $ query "SELECT status FROM message_dispatches WHERE canonical_message_id=?" (Only message.unCanonicalMessageId)
    state `shouldBe` [Only ("completed" :: Text)]

  it "reads late inputs before delegating and closes admission after successful delegation" $ do
    (front, message, actor) <- seed pool 900 1
    withDb pool (claimFrontend front) `shouldReturn` True
    (incoming, _, _) <- seed pool 900 1
    withDb pool (admitFrontend incoming (Just FeedbackInput)) `shouldReturn` FrontendInputQueued
    let delegate = admitTaskReceipt front message actor "delegate" "work" Research (object []) Map.empty
    withDb pool delegate `shouldReturn` Left AdmissionInputPending
    _ <- withDb pool (readInputs front.atrTurnId)
    accepted <- withDb pool delegate
    accepted `shouldSatisfy` either (const False) (const True)
    (later, _, _) <- seed pool 900 1
    withDb pool (admitFrontend later (Just FeedbackInput)) `shouldReturn` FrontendBusy
  it "queues independent questions and mentions even from the current author" $ do
    (front, _, _) <- seed pool 900 1
    withDb pool (claimFrontend front) `shouldReturn` True
    (same, _, _) <- seed pool 900 1
    (other, _, _) <- seed pool 900 2
    withDb pool (admitFrontend same (Just MessageInput)) `shouldReturn` FrontendBusy
    withDb pool (admitFrontend same (Just MentionInput)) `shouldReturn` FrontendBusy
    withDb pool (admitFrontend other (Just MentionInput)) `shouldReturn` FrontendBusy
    withDb pool (readInputs front.atrTurnId) `shouldReturn` ""

  it "settles observed feedback with the ordinary reply and queues unseen feedback" $ do
    (front, _, _) <- seed pool 900 1
    withDb pool (claimFrontend front) `shouldReturn` True
    (observed, _, _) <- seed pool 900 1
    withDb pool (admitFrontend observed (Just FeedbackInput)) `shouldReturn` FrontendInputQueued
    _ <- withDb pool (readInputs front.atrTurnId)
    (unseen, message, _) <- seed pool 900 1
    withDb pool (admitFrontend unseen (Just FeedbackInput)) `shouldReturn` FrontendInputQueued
    void $ withDb pool (enqueueOutbound (draft front))
    withDb pool (finishAgentTurn front TurnSucceeded 1 Nothing)
    dispositions pool front `shouldReturn` ["answered", "answered", "pending"]
    withDb pool (pendingRequest message.unCanonicalMessageId) `shouldReturn` True
    rows <- withDb pool $ query "SELECT status FROM message_dispatches WHERE canonical_message_id=?" (Only message.unCanonicalMessageId)
    rows `shouldBe` [Only ("pending" :: Text)]

  it "never loses feedback racing with final publication" $ do
    (front, _, _) <- seed pool 900 1
    withDb pool (claimFrontend front) `shouldReturn` True
    (incoming, message, _) <- seed pool 900 1
    void $ withDb pool (enqueueOutbound (draft front))
    (admitted, ()) <-
      concurrently
        (withDb pool (admitFrontend incoming (Just FeedbackInput)))
        (withDb pool (finishAgentTurn front TurnSucceeded 1 Nothing))
    case admitted of
      FrontendInputQueued -> withDb pool (pendingRequest message.unCanonicalMessageId) `shouldReturn` True
      FrontendClaimed -> withDb pool (claimFrontend incoming) `shouldReturn` True
      FrontendBusy -> expectationFailure "released frontend should admit the next turn"

dispositions :: DbPool -> AgentTurnRef -> IO [Text]
dispositions pool turn = do
  rows <- withDb pool $ query "SELECT disposition FROM conversation_requests WHERE turn_id=? ORDER BY message_id" (Only turn.atrTurnId)
  pure [value | Only value <- rows]
