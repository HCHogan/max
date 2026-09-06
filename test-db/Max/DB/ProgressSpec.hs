module Max.DB.ProgressSpec (spec) where

import Control.Concurrent.Async (concurrently)
import Control.Monad (void)
import Data.Aeson (object, (.=))
import Data.Int (Int64)
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Database.PostgreSQL.Simple (Only (..))
import Database.PostgreSQL.Simple.FromRow (field)
import Effectful.PostgreSQL (execute, query)
import Helpers (requireJust, truncateAll, withDb, withDbLog)
import Max.DB.AgentTurn
import Max.DB.Connection (DbPool)
import Max.DB.Codec (jsonField, queryRows)
import Max.DB.Health (operationalChecks)
import Max.DB.Task
import Max.DB.Task.Progress
import Max.DB.Task.Query qualified as Query
import Max.DB.TaskSpec (admit, claimOne, draft, report, seed)
import Max.Effects.Outbound (runOutbound)
import Max.Execution.Types (ExecutionStep (ExecutionCheckpoint))
import Max.IR (Body (..), Node (NMention, NText), Phase (Canonical))
import Max.Platform.Store (OutboundDraft (..), enqueueOutbound)
import Max.Platform.Types (PrincipalId (..))
import Max.ReplySend
import Max.Task.Progress
import Max.Task.Query qualified as TaskView
import Max.Turn.Types
import OneBot.Types (GroupId (..))
import Test.Hspec

spec :: DbPool -> Spec
spec pool = before_ (truncateAll pool) $ describe "versioned progress review" $ do
  it "settles skip without a message, delivery receipt, failed obligation or retry" $ do
    (task, _, front) <- ready pool
    snapshot <- withDb pool (loadProgressReview front.atrTurnId) >>= requireJust "review"
    snapshot.version `shouldBe` 1
    withDb pool (progressReviewHandled front.atrTurnId) `shouldReturn` False
    withDb pool (recordProgressDecision front.atrTurnId 1 (SkipProgress "already explained")) `shouldReturn` True
    withDb pool (progressReviewHandled front.atrTurnId) `shouldReturn` True
    withDb pool (enqueueOutbound (draft front)) `shouldThrow` anyException
    withDb pool (finishAgentTurn front TurnSucceeded 1 Nothing Nothing)
    withDb pool admitTaskNotification `shouldReturn` []
    rows <- withDb pool $ query "SELECT delivered_at IS NULL,review_decision->>'action',attempts FROM task_notifications WHERE task_id=?" (Only task)
    rows `shouldBe` [(True, "skip" :: Text, 1 :: Int)]
    requests <- withDb pool $ query "SELECT disposition FROM conversation_requests" ()
    requests `shouldBe` [Only ("delegated" :: Text)]
    detail <- withDb pool (Query.readTask (GroupId 900) task) >>= requireJust "task detail"
    progressView <- requireJust "progress" detail.progress
    progressView.reviewDecision `shouldBe` Just (SkipProgress "already explained")
    progressView.reviewedAt `shouldSatisfy` isJust
    void $ withDb pool $ execute "UPDATE task_notifications SET attempts=15" ()
    case [sql | (name, _, sql) <- operationalChecks, name == "task_notification_exhausted"] of
      [sql] -> withDb pool (query sql ()) `shouldReturn` [Only (0 :: Int64)]
      _ -> expectationFailure "missing notification health check"

  it "reviews a new version after skip and never treats skipped prose as published context" $ do
    (_, execution, front) <- ready pool
    withDb pool (recordProgressDecision front.atrTurnId 1 (SkipProgress "duplicate")) `shouldReturn` True
    withDb pool (finishAgentTurn front TurnSucceeded 1 Nothing Nothing)
    progress pool execution "new evidence"
    due pool
    [next] <- withDb pool admitTaskNotification
    Just nextFront <- withDb pool (taskTurnRef next)
    withDb pool (claimFrontend nextFront) `shouldReturn` True
    nextReview <- withDb pool (loadProgressReview next) >>= requireJust "next review"
    nextReview.version `shouldBe` 2
    nextReview.previousPublished `shouldBe` Nothing
    withDb pool (recordProgressDecision next 1 (SkipProgress "old version")) `shouldReturn` False

  it "rejects publication before a decision, and fences an already-decided older version" $ do
    (_, execution, front) <- ready pool
    withDb pool (enqueueOutbound (draft front)) `shouldThrow` anyException
    withDb pool (recordProgressDecision front.atrTurnId 1 useful) `shouldReturn` True
    progress pool execution "newer snapshot"
    withDb pool (progressReviewCurrent front.atrTurnId) `shouldReturn` False
    withDb pool (enqueueOutbound (draft front)) `shouldThrow` anyException
    withDb pool (recordProgressDecision front.atrTurnId 1 useful) `shouldReturn` False
    withDb pool (notificationKind front.atrTurnId) `shouldReturn` Just "progress"

  it "allows a real foreground request to preempt an unpublished review and fences its late response" $ do
    (_, _, front) <- ready pool
    withDb pool (recordProgressDecision front.atrTurnId 1 useful) `shouldReturn` True
    (userTurn, _, _) <- seed pool 900 2
    withDb pool (claimFrontend userTurn) `shouldReturn` True
    withDb pool (progressReviewCurrent front.atrTurnId) `shouldReturn` False
    withDb pool (enqueueOutbound (draft front)) `shouldThrow` anyException
    withDb pool (finishAgentTurn front TurnAborted 0 (Just "yielded") Nothing)
    withDb pool (authorizeTaskStep userTurn.atrTurnId ExecutionCheckpoint) `shouldReturn` True
    withDb pool admitTaskNotification `shouldReturn` []
    withDb pool (finishAgentTurn userTurn TurnSucceeded 1 Nothing Nothing)
    due pool
    [next] <- withDb pool admitTaskNotification
    Just nextFront <- withDb pool (taskTurnRef next)
    withDb pool (claimFrontend nextFront) `shouldReturn` True
    snapshot <- withDb pool (loadProgressReview next) >>= requireJust "fresh context review"
    snapshot.decision `shouldBe` Nothing

  it "does not admit progress ahead of already-waiting foreground work" $ do
    source <- seed pool 900 1
    _ <- admit pool source "priority"
    execution <- claimOne pool
    progress pool execution "working"
    (userTurn, _, _) <- seed pool 900 2
    withDb pool admitTaskNotification `shouldReturn` []
    withDb pool (claimFrontend userTurn) `shouldReturn` True

  it "serializes a request takeover racing a decision without granting the old writer" $ do
    (_, _, front) <- ready pool
    (userTurn, _, _) <- seed pool 900 2
    (_, acquired) <- concurrently
      (withDb pool (recordProgressDecision front.atrTurnId 1 useful))
      (withDb pool (claimFrontend userTurn))
    acquired `shouldBe` True
    withDb pool (enqueueOutbound (draft front)) `shouldThrow` anyException

  it "leaves model failure retryable without emitting a fallback report" $ do
    (_, _, front) <- ready pool
    withDb pool (finishAgentTurn front TurnFailed 1 (Just "malformed model response") Nothing)
    withDb pool admitTaskNotification `shouldReturn` []
    rows <- withDb pool $ query "SELECT review_decision IS NULL,delivered_at IS NULL,last_error FROM task_notifications" ()
    rows `shouldBe` [(True, True, "malformed model response" :: Text)]
    due pool
    [_] <- withDb pool admitTaskNotification
    receipts <- withDb pool $ query "SELECT count(*) FROM messages WHERE agent_turn_id IS NOT NULL" ()
    receipts `shouldBe` [Only (0 :: Int64)]

  it "acknowledges one committed progress output after a failed terminal checkpoint without republishing" $ do
    (_, execution, front) <- ready pool
    withDb pool (recordProgressDecision front.atrTurnId 1 useful) `shouldReturn` True
    void $ withDb pool (enqueueOutbound (draft front))
    withDb pool (enqueueOutbound ((draft front) {turnOutputLink=Just (TurnOutputLink front.atrTurnId 1)})) `shouldThrow` anyException
    withDb pool (loadProgressReview front.atrTurnId) `shouldReturn` Nothing
    withDb pool (finishAgentTurn front TurnCrashed 0 (Just "died after publication") Nothing)
    due pool
    withDb pool admitTaskNotification `shouldReturn` []
    receipts <- withDb pool $ query "SELECT delivered_at IS NOT NULL FROM task_notifications" ()
    receipts `shouldBe` [Only True]
    progress pool execution "another useful update"
    due pool
    [next] <- withDb pool admitTaskNotification
    Just nextFront <- withDb pool (taskTurnRef next)
    withDb pool (claimFrontend nextFront) `shouldReturn` True
    snapshot <- withDb pool (loadProgressReview next) >>= requireJust "review after publication"
    snapshot.previousPublished `shouldBe` Just "task report"

  it "recovers the publication-to-checkpoint crash window before allocating another review turn" $ do
    (_, _, front) <- ready pool
    withDb pool (recordProgressDecision front.atrTurnId 1 useful) `shouldReturn` True
    withDb pool (progressReviewHandled front.atrTurnId) `shouldReturn` False
    void $ withDb pool (enqueueOutbound (draft front))
    withDb pool (progressReviewHandled front.atrTurnId) `shouldReturn` True
    void $ withDb pool $ execute "UPDATE agent_turns SET status='crashed' WHERE turn_id=?" (Only front.atrTurnId)
    void $ withDb pool $ execute "DELETE FROM conversation_frontends WHERE turn_id=?" (Only front.atrTurnId)
    withDb pool admitTaskNotification `shouldReturn` []
    rows <- withDb pool $ query "SELECT attempts,delivered_at IS NOT NULL FROM task_notifications" ()
    rows `shouldBe` [(1 :: Int, True)]
    withDb pool admitTaskNotification `shouldReturn` []

  mapM_ (\operation -> it ("fences a publish decision after task " <> T.unpack operation) $ do
    (task, _, front) <- ready pool
    withDb pool (recordProgressDecision front.atrTurnId 1 useful) `shouldReturn` True
    [Only actor] <- withDb pool $ query "SELECT owner_principal_id FROM durable_tasks WHERE task_id=?" (Only task)
    void $ withDb pool (taskControl (GroupId 900) (PrincipalId actor) False task operation (Just 1) Nothing "changed objective")
    withDb pool (progressReviewCurrent front.atrTurnId) `shouldReturn` False
    withDb pool (enqueueOutbound (draft front)) `shouldThrow` anyException)
    ["cancel", "replace"]

  it "supersedes a decided progress notification when the task finishes, preserving the result path" $ do
    (_, execution, front) <- ready pool
    withDb pool (recordProgressDecision front.atrTurnId 1 useful) `shouldReturn` True
    withDb pool (taskReport execution.atrTurnId (report "succeeded")) `shouldReturn` True
    withDb pool (finishAgentTurn execution TurnSucceeded 1 Nothing Nothing)
    withDb pool (enqueueOutbound (draft front)) `shouldThrow` anyException
    withDb pool (finishAgentTurn front TurnAborted 0 Nothing Nothing)
    [result] <- withDb pool admitTaskNotification
    withDb pool (notificationKind result) `shouldReturn` Just "result"

  it "publishes one canonical message through the shared mention and reply resolver" $ do
    (_, _, front) <- ready pool
    [Only principal] <- withDb pool $ query "SELECT author_principal_id FROM messages ORDER BY canonical_message_id LIMIT 1" ()
    [Only source] <- withDb pool $ query "SELECT canonical_message_id FROM messages ORDER BY canonical_message_id LIMIT 1" ()
    output <- newTurnOutputContext front
    let text = "[reply#" <> T.pack (show (source :: Int64)) <> "] [mention#" <> T.pack (show (principal :: Int64)) <> ": Alice] 新证据\n\n正在验证"
        target = ReplyTarget (GroupId 900) [("Alice",PrincipalId principal)] Nothing False True True False False (Just output)
    withDb pool (recordProgressDecision front.atrTurnId 1 (PublishProgress text "useful")) `shouldReturn` True
    published <- withDbLog pool $ runOutbound $ sendAndPersistReply target (freshBudget {sbChunksLeft=1}) text
    length published.committed `shouldBe` 1
    published.failure `shouldBe` Nothing
    rows <- withDb pool $ queryRows ((,) <$> jsonField <*> field) "SELECT canonical_content::text,reply_to_canonical_message_id FROM messages WHERE agent_turn_id=?" (Only front.atrTurnId)
    case rows of
      [(body :: Body 'Canonical, reply :: Maybe Int64)] -> do
        length [() | NMention {} <- body.nodes] `shouldBe` 1
        reply `shouldBe` Just source
        [value | NText value <- body.nodes] `shouldSatisfy` (not . any (T.isInfixOf "mention#"))
      _ -> expectationFailure "missing canonical publication"

ready :: DbPool -> IO (Int64, AgentTurnRef, AgentTurnRef)
ready pool = do
  source <- seed pool 900 1
  task <- admit pool source "progress-review"
  execution <- claimOne pool
  progress pool execution "first evidence"
  [notice] <- withDb pool admitTaskNotification
  Just front <- withDb pool (taskTurnRef notice)
  withDb pool (claimFrontend front) `shouldReturn` True
  pure (task, execution, front)

progress :: DbPool -> AgentTurnRef -> Text -> IO ()
progress pool execution text = withDb pool (recordTaskProgress execution.atrTurnId (object ["summary" .= text])) `shouldReturn` True

due :: DbPool -> IO ()
due pool = void $ withDb pool $ execute "UPDATE task_notifications SET next_attempt_at=now()-interval '1 second'" ()

useful :: ProgressDecision
useful = PublishProgress "task report" "useful progress"
