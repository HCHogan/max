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
import Max.DB.Task.Reporting (submitRequestWithInputs)
import Max.DB.TaskSpec (draft, seed)
import Max.Platform.Store (DispatchClaim (..), DispatchCompletion (..), claimDispatch, completeDispatch, enqueueOutbound, startDispatch)
import Max.Platform.Types (CanonicalMessageId (..))
import Max.Task.Admission (AdmissionError (..))
import Max.Task.Execution (ExecutionFailure (..))
import Max.Task.State
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
    withDb pool (admitFrontend incoming (Just True)) `shouldReturn` FrontendInputQueued
    requests <- withDb pool $ query "SELECT turn_id,disposition FROM conversation_requests WHERE message_id=?" (Only message.unCanonicalMessageId)
    requests `shouldBe` [(front.atrTurnId, "pending" :: Text)]
    state <- withDb pool $ query "SELECT status FROM agent_turns WHERE turn_id=?" (Only incoming.atrTurnId)
    state `shouldBe` [Only ("aborted" :: Text)]
    dispatch <- withDb pool $ query "SELECT status FROM message_dispatches WHERE canonical_message_id=?" (Only message.unCanonicalMessageId)
    dispatch `shouldBe` [Only ("completed" :: Text)]

  it "does not inject another principal or a separately requested frontend" $ do
    (front, _, _) <- seed pool 900 1
    withDb pool (claimFrontend front) `shouldReturn` True
    (other, _, _) <- seed pool 900 2
    (separate, _, _) <- seed pool 900 1
    withDb pool (admitFrontend other (Just True)) `shouldReturn` FrontendBusy
    withDb pool (admitFrontend separate Nothing) `shouldReturn` FrontendBusy
    withDb pool (readInputs front.atrTurnId) `shouldReturn` ""

  it "retains ingress order, reply provenance and canonical text without grouping kinds" $ do
    (front, trigger, _) <- seed pool 900 1
    withDb pool (claimFrontend front) `shouldReturn` True
    (first, firstMessage, _) <- seed pool 900 1
    (second, secondMessage, _) <- seed pool 900 1
    void $ withDb pool $ execute "UPDATE messages SET rendered_text='first input' WHERE canonical_message_id=?" (Only firstMessage.unCanonicalMessageId)
    void $ withDb pool $ execute "UPDATE messages SET rendered_text='second input',reply_to_canonical_message_id=? WHERE canonical_message_id=?" (trigger.unCanonicalMessageId, secondMessage.unCanonicalMessageId)
    withDb pool (admitFrontend second (Just False)) `shouldReturn` FrontendInputQueued
    withDb pool (admitFrontend first (Just False)) `shouldReturn` FrontendInputQueued
    body <- withDb pool (readInputs front.atrTurnId)
    let entries = filter (T.isPrefixOf "{") (T.lines body)
    case entries of
      [firstEntry, secondEntry] -> do
        firstEntry `shouldSatisfy` T.isInfixOf "first input"
        firstEntry `shouldSatisfy` T.isInfixOf "\"kind\":\"message\""
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
    (left, right) <- concurrently (withDb pool (admitFrontend incoming (Just True))) (withDb pool (admitFrontend duplicate (Just True)))
    (left, right) `shouldBe` (FrontendInputQueued, FrontendInputQueued)
    count <- withDb pool $ query "SELECT count(*) FROM frontend_inputs WHERE message_id=?" (Only message.unCanonicalMessageId)
    count `shouldBe` [Only (1 :: Int64)]

  it "rejects an unseen input before finish and only settles explicitly named inputs after publication" $ do
    (front, _, _) <- seed pool 900 1
    withDb pool (claimFrontend front) `shouldReturn` True
    (incoming, message, _) <- seed pool 900 1
    withDb pool (admitFrontend incoming (Just True)) `shouldReturn` FrontendInputQueued
    withDb pool (submitRequestWithInputs front.atrTurnId RequestAnswered "reply" []) `shouldReturn` Left ExecutionInputPending
    _ <- withDb pool (readInputs front.atrTurnId)
    let inputs = [RequestInputOutcome message.unCanonicalMessageId RequestWaiting]
    withDb pool (submitRequestWithInputs front.atrTurnId RequestAnswered "reply" inputs) `shouldReturn` Right ()
    withDb pool (submitRequestWithInputs front.atrTurnId RequestAnswered "reply" inputs) `shouldReturn` Right ()
    withDb pool (submitRequestWithInputs front.atrTurnId RequestAnswered "reply" []) `shouldReturn` Left ExecutionReportRejected
    dispositions pool front `shouldReturn` ["pending", "pending"]
    void $ withDb pool (enqueueOutbound (draft front))
    withDb pool (finishAgentTurn front TurnSucceeded 1 Nothing Nothing)
    dispositions pool front `shouldReturn` ["answered", "waiting"]

  it "rejects fabricated, duplicate or unowned input dispositions" $ do
    (front, message, _) <- seed pool 900 1
    withDb pool (claimFrontend front) `shouldReturn` True
    let ownTrigger = RequestInputOutcome message.unCanonicalMessageId RequestAnswered
    withDb pool (submitRequestWithInputs front.atrTurnId RequestAnswered "reply" [ownTrigger]) `shouldReturn` Left ExecutionReportRejected
    (incoming, inputMessage, _) <- seed pool 900 1
    withDb pool (admitFrontend incoming (Just True)) `shouldReturn` FrontendInputQueued
    _ <- withDb pool (readInputs front.atrTurnId)
    let input = RequestInputOutcome inputMessage.unCanonicalMessageId RequestAnswered
    withDb pool (submitRequestWithInputs front.atrTurnId RequestAnswered "reply" [input, input]) `shouldReturn` Left ExecutionReportRejected

  it "hands unlisted observed inputs back to dispatch after a successful reply" $ do
    (front, _, _) <- seed pool 900 1
    withDb pool (claimFrontend front) `shouldReturn` True
    (incoming, message, _) <- seed pool 900 1
    withDb pool (admitFrontend incoming (Just False)) `shouldReturn` FrontendInputQueued
    _ <- withDb pool (readInputs front.atrTurnId)
    withDb pool (submitRequestWithInputs front.atrTurnId RequestAnswered "reply" []) `shouldReturn` Right ()
    void $ withDb pool (enqueueOutbound (draft front))
    withDb pool (finishAgentTurn front TurnSucceeded 1 Nothing Nothing)
    dispositions pool front `shouldReturn` ["answered", "pending"]
    state <- withDb pool $ query "SELECT status FROM message_dispatches WHERE canonical_message_id=?" (Only message.unCanonicalMessageId)
    state `shouldBe` [Only ("pending" :: Text)]

  it "returns named inputs to dispatch when reply publication fails" $ do
    (front, _, _) <- seed pool 900 1
    withDb pool (claimFrontend front) `shouldReturn` True
    (incoming, message, _) <- seed pool 900 1
    withDb pool (admitFrontend incoming (Just True)) `shouldReturn` FrontendInputQueued
    _ <- withDb pool (readInputs front.atrTurnId)
    withDb pool (submitRequestWithInputs front.atrTurnId RequestAnswered "reply" [RequestInputOutcome message.unCanonicalMessageId RequestAnswered]) `shouldReturn` Right ()
    withDb pool (finishAgentTurn front TurnFailed 1 (Just "publication failed") Nothing)
    dispositions pool front `shouldReturn` ["failed", "pending"]

  it "retains eligibility for a deferred intent trigger without an active dispatch owner" $ do
    (front, _, _) <- seed pool 900 1
    withDb pool (claimFrontend front) `shouldReturn` True
    withDb pool (submitRequestWithInputs front.atrTurnId RequestAnswered "reply" []) `shouldReturn` Right ()
    (incoming, message, _) <- seed pool 900 1
    withDb pool (admitFrontend incoming (Just False)) `shouldReturn` FrontendBusy
    now <- getCurrentTime
    withDb pool (deferRequest incoming.atrTurnId now)
    withDb pool (finishAgentTurn incoming TurnAborted 0 Nothing Nothing)
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
    withDb pool (admitFrontend incoming (Just True)) `shouldReturn` FrontendInputQueued
    duplicateClaim <- withDb pool (claimDispatch "duplicate" message 120)
    fmap (.canonicalMessageId) duplicateClaim `shouldBe` Nothing
    withDb pool (finishAgentTurn front TurnFailed 1 Nothing Nothing)
    Just retryClaim <- withDb pool (claimDispatch "retry" message 120)
    withDb pool (startDispatch "retry" message retryClaim.attemptCount 120) `shouldReturn` True
    withDb pool (completeDispatch "original" message claim.attemptCount DispatchCompleted) `shouldReturn` False
    state <- withDb pool $ query "SELECT status,lease_owner FROM message_dispatches WHERE canonical_message_id=?" (Only message.unCanonicalMessageId)
    state `shouldBe` [("claimed" :: Text, Just ("retry" :: Text))]

  it "does not let a duplicate deferred source resurrect an already assigned input" $ do
    (front, _, _) <- seed pool 900 1
    withDb pool (claimFrontend front) `shouldReturn` True
    (incoming, message, actor) <- seed pool 900 1
    withDb pool (admitFrontend incoming (Just True)) `shouldReturn` FrontendInputQueued
    _ <- withDb pool (readInputs front.atrTurnId)
    withDb pool (submitRequestWithInputs front.atrTurnId RequestAnswered "reply" [RequestInputOutcome message.unCanonicalMessageId RequestAnswered]) `shouldReturn` Right ()
    duplicate <- withDb pool (startAgentTurn (GroupId 900) message actor)
    withDb pool (admitFrontend duplicate (Just True)) `shouldReturn` FrontendBusy
    now <- getCurrentTime
    withDb pool (deferRequest duplicate.atrTurnId now)
    void $ withDb pool (enqueueOutbound (draft front))
    withDb pool (finishAgentTurn front TurnSucceeded 1 Nothing Nothing)
    state <- withDb pool $ query "SELECT status FROM message_dispatches WHERE canonical_message_id=?" (Only message.unCanonicalMessageId)
    state `shouldBe` [Only ("completed" :: Text)]

  it "closes input admission after finish, so a later message retains its own turn" $ do
    (front, _, _) <- seed pool 900 1
    withDb pool (claimFrontend front) `shouldReturn` True
    withDb pool (submitRequestWithInputs front.atrTurnId RequestAnswered "reply" []) `shouldReturn` Right ()
    (incoming, _, _) <- seed pool 900 1
    withDb pool (admitFrontend incoming (Just True)) `shouldReturn` FrontendBusy

  it "serializes input admission against terminal intent without losing either side of the race" $ do
    (front, _, _) <- seed pool 900 1
    withDb pool (claimFrontend front) `shouldReturn` True
    (incoming, _, _) <- seed pool 900 1
    result <-
      concurrently
        (withDb pool (admitFrontend incoming (Just True)))
        (withDb pool (submitRequestWithInputs front.atrTurnId RequestAnswered "reply" []))
    result `shouldSatisfy` (`elem` [(FrontendInputQueued, Left ExecutionInputPending), (FrontendBusy, Right ())])

  it "replays observed inputs when the same durable frontend recovers" $ do
    (front, _, _) <- seed pool 900 1
    withDb pool (claimFrontend front) `shouldReturn` True
    (incoming, _, _) <- seed pool 900 1
    withDb pool (admitFrontend incoming (Just True)) `shouldReturn` FrontendInputQueued
    original <- withDb pool (readInputs front.atrTurnId)
    withDb pool (ensureAgentTurnRecoveryPending front "restart")
    withDb pool (claimFrontend front) `shouldReturn` True
    withDb pool (readInputs front.atrTurnId) `shouldReturn` original

  it "keeps terminal input admission closed across recovery" $ do
    (front, _, _) <- seed pool 900 1
    withDb pool (claimFrontend front) `shouldReturn` True
    withDb pool (submitRequestWithInputs front.atrTurnId RequestAnswered "reply" []) `shouldReturn` Right ()
    withDb pool (ensureAgentTurnRecoveryPending front "restart")
    withDb pool (claimFrontend front) `shouldReturn` True
    (incoming, _, _) <- seed pool 900 1
    withDb pool (admitFrontend incoming (Just True)) `shouldReturn` FrontendBusy

  it "cancels assigned inputs without resurrecting their dispatches" $ do
    (front, _, _) <- seed pool 900 1
    withDb pool (claimFrontend front) `shouldReturn` True
    (incoming, message, _) <- seed pool 900 1
    withDb pool (admitFrontend incoming (Just True)) `shouldReturn` FrontendInputQueued
    withDb pool (finishAgentTurn front TurnCancelled 1 (Just "kill") Nothing)
    dispositions pool front `shouldReturn` ["cancelled", "cancelled"]
    state <- withDb pool $ query "SELECT status FROM message_dispatches WHERE canonical_message_id=?" (Only message.unCanonicalMessageId)
    state `shouldBe` [Only ("completed" :: Text)]

  it "reads late inputs before delegating and closes admission after successful delegation" $ do
    (front, message, actor) <- seed pool 900 1
    withDb pool (claimFrontend front) `shouldReturn` True
    (incoming, _, _) <- seed pool 900 1
    withDb pool (admitFrontend incoming (Just True)) `shouldReturn` FrontendInputQueued
    let delegate = admitTaskReceipt front message actor "delegate" "work" Research (object []) Map.empty
    withDb pool delegate `shouldReturn` Left AdmissionInputPending
    _ <- withDb pool (readInputs front.atrTurnId)
    accepted <- withDb pool delegate
    accepted `shouldSatisfy` either (const False) (const True)
    (later, _, _) <- seed pool 900 1
    withDb pool (admitFrontend later (Just True)) `shouldReturn` FrontendBusy

dispositions :: DbPool -> AgentTurnRef -> IO [Text]
dispositions pool turn = do
  rows <- withDb pool $ query "SELECT disposition FROM conversation_requests WHERE turn_id=? ORDER BY message_id" (Only turn.atrTurnId)
  pure [value | Only value <- rows]
