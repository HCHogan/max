module Max.DB.ProgressSpec (spec) where

import Control.Monad (void)
import Data.Aeson (object, (.=))
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as T
import Database.PostgreSQL.Simple (Only (..))
import Database.PostgreSQL.Simple.FromRow (field)
import Effectful.PostgreSQL (execute, query)
import Helpers (requireJust, truncateAll, withDb, withDbLog)
import Max.DB.AgentTurn
import Max.DB.Codec (jsonField, queryRows)
import Max.DB.Connection (DbPool)
import Max.DB.Task
import Max.DB.Task.Notice
import Max.DB.Task.Query qualified as Query
import Max.DB.TaskSpec (admit, claimOne, draft, report, seed)
import Max.Effects.Outbound (runOutbound)
import Max.Execution.Types (ExecutionStep (ExecutionCheckpoint))
import Max.IR (Body (..), Node (NMention, NText), Phase (Canonical))
import Max.Platform.Store (OutboundDraft (..), enqueueOutbound)
import Max.Platform.Types (PrincipalId (..))
import Max.ReplySend
import Max.Task.Notice
import Max.Task.Query qualified as TaskView
import Max.Task.State qualified as TaskState
import Max.Turn.Types
import OneBot.Types (GroupId (..))
import Test.Hspec

spec :: DbPool -> Spec
spec pool = before_ (truncateAll pool) $ describe "direct task publication" $ do
  it "publishes progress directly and retains it in task status" $ do
    (task, _, front) <- ready pool
    withDb pool (loadNotice front.atrTurnId) `shouldReturn` Just (TaskProgress task "first evidence")
    withDb pool (noticePublished front.atrTurnId) `shouldReturn` False
    void $ withDb pool (enqueueOutbound (draft front))
    withDb pool (noticePublished front.atrTurnId) `shouldReturn` True
    withDb pool (finishAgentTurn front TurnSucceeded 0 Nothing Nothing)
    due pool
    withDb pool admitTaskNotification `shouldReturn` []
    detail <- withDb pool (Query.readTask (GroupId 900) task) >>= requireJust "task detail"
    progressView <- requireJust "progress" detail.progress
    progressView.body `shouldBe` object ["status" .= ("running" :: Text), "summary" .= ("first evidence" :: Text)]
    withDb pool (query "SELECT disposition FROM conversation_requests" ()) `shouldReturn` [Only ("delegated" :: Text)]

  it "returns the final report directly without recording a model decision" $ do
    (task, front) <- readyResult pool
    withDb pool (loadNotice front.atrTurnId) `shouldReturn` Just (TaskResult task (report TaskState.ReportSucceeded))
    void $ withDb pool (enqueueOutbound (draft front))
    withDb pool (finishAgentTurn front TurnSucceeded 0 Nothing Nothing)
    withDb pool (query "SELECT review_decision IS NULL,delivered_at IS NOT NULL FROM task_notifications" ()) `shouldReturn` [(True, True)]
    withDb pool (query "SELECT disposition FROM conversation_requests" ()) `shouldReturn` [Only ("answered" :: Text)]

  it "fences an old progress snapshot after new evidence arrives" $ do
    (_, execution, front) <- ready pool
    progress pool execution "newer snapshot"
    withDb pool (loadNotice front.atrTurnId) `shouldReturn` Nothing
    withDb pool (enqueueOutbound (draft front)) `shouldThrow` anyException

  it "allows a real foreground request to preempt a task notice and fences its late response" $ do
    (task, _, front) <- ready pool
    (userTurn, _, _) <- seed pool 900 2
    withDb pool (claimFrontend userTurn) `shouldReturn` True
    withDb pool (loadNotice front.atrTurnId) `shouldReturn` Nothing
    withDb pool (enqueueOutbound (draft front)) `shouldThrow` anyException
    withDb pool (finishAgentTurn front TurnAborted 0 (Just "yielded") Nothing)
    withDb pool (authorizeTaskStep userTurn.atrTurnId ExecutionCheckpoint) `shouldReturn` True
    withDb pool admitTaskNotification `shouldReturn` []
    withDb pool (finishAgentTurn userTurn TurnSucceeded 1 Nothing Nothing)
    due pool
    [next] <- withDb pool admitTaskNotification
    Just nextFront <- withDb pool (taskTurnRef next)
    withDb pool (claimFrontend nextFront) `shouldReturn` True
    snapshot <- withDb pool (loadNotice next) >>= requireJust "current notice"
    snapshot `shouldBe` TaskProgress task "first evidence"

  it "does not admit progress ahead of already-waiting foreground work" $ do
    source <- seed pool 900 1
    _ <- admit pool source "priority"
    execution <- claimOne pool
    progress pool execution "working"
    (userTurn, _, _) <- seed pool 900 2
    withDb pool admitTaskNotification `shouldReturn` []
    withDb pool (claimFrontend userTurn) `shouldReturn` True

  it "acknowledges one committed progress output after a failed terminal checkpoint without republishing" $ do
    (task, execution, front) <- ready pool
    void $ withDb pool (enqueueOutbound (draft front))
    withDb pool (enqueueOutbound ((draft front) {turnOutputLink = Just (TurnOutputLink front.atrTurnId 1)})) `shouldThrow` anyException
    withDb pool (loadNotice front.atrTurnId) `shouldReturn` Nothing
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
    snapshot <- withDb pool (loadNotice next) >>= requireJust "notice after publication"
    snapshot `shouldBe` TaskProgress task "another useful update"

  it "recovers the publication-to-checkpoint crash window before allocating another notification turn" $ do
    (_, _, front) <- ready pool
    withDb pool (noticePublished front.atrTurnId) `shouldReturn` False
    void $ withDb pool (enqueueOutbound (draft front))
    withDb pool (noticePublished front.atrTurnId) `shouldReturn` True
    void $ withDb pool $ execute "UPDATE agent_turns SET status='crashed' WHERE turn_id=?" (Only front.atrTurnId)
    void $ withDb pool $ execute "DELETE FROM conversation_frontends WHERE turn_id=?" (Only front.atrTurnId)
    withDb pool admitTaskNotification `shouldReturn` []
    rows <- withDb pool $ query "SELECT attempts,delivered_at IS NOT NULL FROM task_notifications" ()
    rows `shouldBe` [(1 :: Int, True)]
    withDb pool admitTaskNotification `shouldReturn` []

  it "supersedes an unpublished progress notification when the task finishes, preserving the result path" $ do
    (_, execution, front) <- ready pool
    withDb pool (taskReportTyped execution.atrTurnId (report TaskState.ReportSucceeded)) `shouldReturn` True
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
        target = ReplyTarget (GroupId 900) [] Nothing False True True False False (Just output)
    published <- withDbLog pool $ runOutbound $ sendAndPersistReply target (freshBudget {sbChunksLeft = 1}) text
    length published.committed `shouldBe` 1
    published.failure `shouldBe` Nothing
    rows <- withDb pool $ queryRows ((,) <$> jsonField <*> field) "SELECT canonical_content::text,reply_to_canonical_message_id FROM messages WHERE agent_turn_id=?" (Only front.atrTurnId)
    case rows of
      [(body :: Body 'Canonical, reply :: Maybe Int64)] -> do
        length [() | NMention {} <- body.nodes] `shouldBe` 1
        reply `shouldBe` Just source
        [value | NText value <- body.nodes] `shouldSatisfy` (not . any (T.isInfixOf "mention#"))
      _ -> expectationFailure "missing canonical publication"

  mapM_
    ( \operation -> it ("fences a pending notice after task " <> T.unpack operation) $ do
        (task, _, front) <- ready pool
        [Only actor] <- withDb pool $ query "SELECT owner_principal_id FROM durable_tasks WHERE task_id=?" (Only task)
        void $ withDb pool (taskControl (GroupId 900) (PrincipalId actor) False task operation (Just 1) Nothing "changed objective")
        withDb pool (loadNotice front.atrTurnId) `shouldReturn` Nothing
        withDb pool (enqueueOutbound (draft front)) `shouldThrow` anyException
    )
    ["cancel", "replace"]

ready :: DbPool -> IO (Int64, AgentTurnRef, AgentTurnRef)
ready pool = do
  source <- seed pool 900 1
  task <- admit pool source "progress-notice"
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

readyResult :: DbPool -> IO (Int64, AgentTurnRef)
readyResult pool = do
  source <- seed pool 900 1
  task <- admit pool source "result-notice"
  execution <- claimOne pool
  withDb pool (taskReportTyped execution.atrTurnId (report TaskState.ReportSucceeded)) `shouldReturn` True
  withDb pool (finishAgentTurn execution TurnSucceeded 1 Nothing Nothing)
  [notice] <- withDb pool admitTaskNotification
  Just front <- withDb pool (taskTurnRef notice)
  withDb pool (claimFrontend front) `shouldReturn` True
  pure (task, front)
