module Max.DB.TaskSpec (spec, seed, admit, claimOne, report, insertOccurrence) where

import Control.Concurrent.Async (concurrently, mapConcurrently)
import Control.Monad (void)
import Data.Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Int (Int64)
import Data.Foldable (for_)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Time (addUTCTime, getCurrentTime)
import Database.PostgreSQL.Simple (Only (..))
import Effectful.PostgreSQL (execute, query)
import Helpers (insertRawMessage, testTime, truncateAll, withDb, withDbLog)
import Max.DB.AgentTurn
import Max.DB.Connection (DbPool)
import Max.DB.Health (operationalChecks)
import Max.Task.Policy (frontendDeadlineSeconds)
import Max.DB.Monitor
import Max.DB.Task
import Max.Effects.Tools (Tool (..))
import Max.IR (Body (..), Node (NText))
import Max.Monitor.Types
import Max.Platform.Store (EnqueuedOutbound (..), OutboundDraft (..), enqueueOutbound)
import Max.Platform.Types (CanonicalMessageId (..), PrincipalId (..), noAdvertisedCaps)
import Max.Task.Types (TaskProfile (..))
import Max.ToolContext
import Max.Tools.Task (taskToolsFor)
import Max.Turn.Types
import OneBot.Types (GroupId (..), UserId (..))
import Test.Hspec

spec :: DbPool -> Spec
spec pool = before_ (truncateAll pool) $ describe "ADR008 durable tasks" $ do
  it "runs every production health query against the current schema" $ do
    for_ operationalChecks $ \(label, _, sql) -> do
      rows <- withDb pool $ query sql ()
      rows `shouldBe` [Only (0 :: Int64)]
      label `shouldNotBe` "plan_expired_wake_claim"

  it "detects expired task/frontend ownership and distinguishes pending requests" $ do
    source <- seed pool 900 1
    _ <- admit pool source "health"
    _ <- claimOne pool
    (front, _, _) <- seed pool 901 1
    withDb pool (claimFrontend front) `shouldReturn` True
    [Only remaining] <- withDb pool $ query "SELECT extract(epoch FROM lease_until-clock_timestamp())::double precision FROM conversation_frontends WHERE turn_id=?" (Only front.atrTurnId)
    (remaining :: Double) `shouldSatisfy` (> fromIntegral frontendDeadlineSeconds)
    void $ withDb pool $ execute "UPDATE task_attempts SET lease_until=now()-interval '1 second'" ()
    void $ withDb pool $ execute "UPDATE durable_tasks SET deadline=now()-interval '1 second'" ()
    void $ withDb pool $ execute "UPDATE conversation_frontends SET lease_until=now()-interval '1 second'" ()
    healthCount pool "task_expired_attempt" `shouldReturn` 1
    healthCount pool "task_overdue_deadline" `shouldReturn` 1
    healthCount pool "frontend_expired_lease" `shouldReturn` 1
    healthCount pool "request_pending" `shouldReturn` 2
    withDb pool (finishAgentTurn front TurnFailed 0 (Just "interrupted") Nothing)
    healthCount pool "request_failed" `shouldReturn` 1
    healthCount pool "frontend_expired_lease" `shouldReturn` 0
    [critical | ("request_pending", critical, _) <- operationalChecks] `shouldBe` [False]

  it "only fails notification health for an exhausted current obligation" $ do
    source <- seed pool 900 1
    _ <- admit pool source "notice-health"
    execution <- claimOne pool
    withDb pool (taskReport execution.atrTurnId success) `shouldReturn` True
    withDb pool (finishAgentTurn execution TurnSucceeded 1 Nothing Nothing)
    void $ withDb pool $ execute "UPDATE task_notifications SET attempts=15" ()
    healthCount pool "task_notification_exhausted" `shouldReturn` 1
    void $ withDb pool $ execute "UPDATE task_notifications SET superseded_at=now()" ()
    healthCount pool "task_notification_exhausted" `shouldReturn` 0

  it "admits once per source key and transfers the source obligation atomically" $ do
    source@(turn, _, _) <- seed pool 900 1
    (left, right) <- concurrently (admit pool source "same") (admit pool source "same")
    left `shouldBe` right
    rows <- withDb pool $ query "SELECT disposition FROM conversation_requests WHERE turn_id=?" (Only turn.atrTurnId)
    rows `shouldBe` [Only ("delegated" :: Text)]

  it "keeps same-author new questions as separate durable obligations" $ do
    first <- seed pool 900 1
    second <- seed pool 900 1
    left <- admit pool first "first"
    right <- admit pool second "second"
    left `shouldNotBe` right
    rows <- withDb pool $ query "SELECT count(*) FROM conversation_requests WHERE disposition='delegated'" ()
    rows `shouldBe` [Only (2 :: Int64)]

  it "does not expose or mutate guessed cross-conversation handles" $ do
    source@(_, _, actor) <- seed pool 900 1
    identifier <- admit pool source "scope"
    missing <- withDb pool (taskStatus (GroupId 901) identifier)
    hasError missing `shouldBe` True
    denied <- withDb pool (taskControl (GroupId 901) actor True identifier "cancel" Nothing Nothing "wrong conversation")
    hasError denied `shouldBe` True

  it "admits browser and sandbox through task_start without an inline Plan schema" $ do
    (turn, message, actor) <- seed pool 900 1
    output <- newTurnOutputContext turn
    let invokeWith grants profile = do
          let toolContext =
                mkToolContext
                  (TurnIdentity (GroupId 900) message (UserId 1) (UserId 99) actor Nothing (Just output))
                  (TurnCapabilities True False False noAdvertisedCaps False grants Nothing False)
          withDbLog pool $ case [tool | tool <- taskToolsFor toolContext, tool.toolName == "task_start"] of
            [tool] -> tool.toolRun (object ["key" .= profile, "objective" .= ("bounded work" :: Text), "profile" .= profile])
            _ -> error "task_start missing"
    denied <- invokeWith Map.empty ("browser" :: Text)
    denied `shouldSatisfy` either (const True) (const False)
    browser <- invokeWith (Map.singleton "browser_navigate" "current-browser-grant") "browser"
    browser `shouldSatisfy` either (const False) (not . hasError)
    sandbox <- invokeWith (Map.singleton "sandbox_exec" "current-sandbox-grant") "sandbox"
    sandbox `shouldSatisfy` either (const False) (not . hasError)

  it "allows attributed suggestions but denies another member's cancellation and replacement" $ do
    source <- seed pool 900 1
    (_, _, other) <- seed pool 900 2
    identifier <- admit pool source "authority"
    suggestion <- withDb pool (taskControl (GroupId 900) other False identifier "steer" Nothing Nothing "a suggestion, not a new goal")
    hasError suggestion `shouldBe` False
    cancelled <- withDb pool (taskControl (GroupId 900) other False identifier "cancel" Nothing Nothing "stop")
    hasError cancelled `shouldBe` True
    replaced <- withDb pool (taskControl (GroupId 900) other False identifier "replace" (Just 1) Nothing "changed")
    hasError replaced `shouldBe` True

  it "runs background work without holding the one frontend activation" $ do
    source@(front, _, _) <- seed pool 900 1
    _ <- admit pool source "background"
    background <- claimOne pool
    withDb pool (claimFrontend front) `shouldReturn` True
    withDb pool (authorizeTaskStep background.atrTurnId (Just "web_search") True) `shouldReturn` True
    (other, _, _) <- seed pool 900 2
    withDb pool (claimFrontend other) `shouldReturn` False
    withDb pool (finishAgentTurn front TurnSucceeded 0 Nothing Nothing)
    withDb pool (claimFrontend other) `shouldReturn` True

  it "fences a frontend after lease takeover, including late publication authority" $ do
    (first, _, _) <- seed pool 900 1
    (second, _, _) <- seed pool 900 2
    withDb pool (claimFrontend first) `shouldReturn` True
    void $ withDb pool $ execute "UPDATE conversation_frontends SET lease_until=now()-interval '1 second'" ()
    withDb pool (claimFrontend second) `shouldReturn` True
    withDb pool (authorizeTaskStep first.atrTurnId (Just "task_finish") False) `shouldReturn` False
    withDb pool (enqueueOutbound (draft first)) `shouldThrow` anyException

  it "blocks direct background publication at the canonical outbox boundary" $ do
    source <- seed pool 900 1
    _ <- admit pool source "no-independent-mouth"
    background <- claimOne pool
    withDb pool (enqueueOutbound (draft background)) `shouldThrow` anyException

  it "cancels durably before a model round and rejects late task reports" $ do
    source@(_, _, actor) <- seed pool 900 1
    identifier <- admit pool source "cancel"
    execution <- claimOne pool
    _ <- withDb pool (taskControl (GroupId 900) actor False identifier "cancel" Nothing Nothing "stop now")
    withDb pool (authorizeTaskStep execution.atrTurnId (Just "web_search") True) `shouldReturn` False
    withDb pool (taskReport execution.atrTurnId success) `shouldReturn` False
    withDb pool (isTaskTurn execution.atrTurnId) `shouldReturn` True
    withDb pool (loadTaskExecution execution.atrTurnId) `shouldReturn` Nothing
    withDb pool (finishAgentTurn execution TurnSucceeded 0 Nothing Nothing)
    status pool identifier `shouldReturn` "cancelled"

  it "replaces with CAS while preserving identity, revision history and spend" $ do
    source@(_, _, actor) <- seed pool 900 1
    identifier <- admit pool source "replace"
    old <- claimOne pool
    withDb pool (authorizeTaskStep old.atrTurnId (Just "web_search") True) `shouldReturn` True
    changed <- withDb pool (taskControl (GroupId 900) actor False identifier "replace" (Just 1) Nothing "new objective")
    hasError changed `shouldBe` False
    stale <- withDb pool (taskControl (GroupId 900) actor False identifier "replace" (Just 1) Nothing "lost update")
    hasError stale `shouldBe` True
    withDb pool (taskReport old.atrTurnId success) `shouldReturn` False
    next <- claimOne pool
    current <- withDb pool (loadTaskExecution next.atrTurnId)
    fmap (.teRevision) current `shouldBe` Just 2
    rows <- withDb pool $ query "SELECT calls_reserved,(SELECT count(*) FROM task_revisions WHERE task_id=work.task_id) FROM durable_tasks work WHERE task_id=?" (Only identifier)
    rows `shouldBe` [(1 :: Int, 2 :: Int64)]

  it "does not lose an event arriving after inbox read but before completion" $ do
    source@(_, _, actor) <- seed pool 900 1
    identifier <- admit pool source "inbox-race"
    execution <- claimOne pool
    withDb pool (taskInbox execution.atrTurnId) `shouldReturn` ""
    withDb pool (taskReport execution.atrTurnId success) `shouldReturn` True
    _ <- withDb pool (taskControl (GroupId 900) actor False identifier "steer" Nothing Nothing "also check the date")
    withDb pool (finishAgentTurn execution TurnSucceeded 1 Nothing Nothing)
    status pool identifier `shouldReturn` "queued"
    next <- claimOne pool
    body <- withDb pool (taskInbox next.atrTurnId)
    body `shouldSatisfy` (/= "")
    withDb pool (taskReport next.atrTurnId success) `shouldReturn` True
    withDb pool (finishAgentTurn next TurnSucceeded 1 Nothing Nothing)
    status pool identifier `shouldReturn` "succeeded"

  it "recovers expired execution with its original budget and unknown effect evidence" $ do
    source <- seed pool 900 1
    identifier <- admit pool source "recover"
    first <- claimOne pool
    withDb pool (authorizeTaskStep first.atrTurnId (Just "web_search") True) `shouldReturn` True
    _ <- withDb pool (startJournalExecution first (JournalStart "first" "web_search" 1 "hash" (object []) (toJSON ([] :: [Text])) "retry-safe"))
    void $ withDb pool $ execute "UPDATE task_attempts SET lease_until=now()-interval '1 second' WHERE turn_id=?" (Only first.atrTurnId)
    second <- claimOne pool
    second `shouldNotBe` first
    withDb pool (taskReport first.atrTurnId success) `shouldReturn` False
    rows <- withDb pool $ query "SELECT calls_reserved FROM durable_tasks WHERE task_id=?" (Only identifier)
    rows `shouldBe` [Only (1 :: Int)]
    journal <- withDb pool $ query "SELECT state FROM execution_journal WHERE turn_id=?" (Only first.atrTurnId)
    journal `shouldBe` [Only ("outcome-unknown" :: Text)]

  it "shares reservations across descendants under parallel requests" $ do
    source@(_, message, actor) <- seed pool 900 1
    identifier <- admit pool source "root-budget"
    parent <- claimOne pool
    child <- withDb pool (admitTask parent message actor "child" "child work" Research (object []) Map.empty)
    hasError child `shouldBe` False
    descendant <- claimOne pool
    void $ withDb pool $ execute "UPDATE durable_tasks SET max_calls=1 WHERE task_id=?" (Only identifier)
    answers <- mapConcurrently (\turn -> withDb pool (authorizeTaskStep turn.atrTurnId (Just "web_search") True)) [parent, descendant]
    length (filter id answers) `shouldBe` 1

  it "prevents nested grants from exceeding the parent grant map" $ do
    source@(_, message, actor) <- seed pool 900 1
    _ <- admit pool source "narrow"
    parent <- claimOne pool
    child <- withDb pool (admitTask parent message actor "widen" "send to chat" Research (object []) (Map.singleton "poke" "invented"))
    hasError child `shouldBe` True

  it "keeps child admission idempotent across parent execution attempts" $ do
    source@(_, message, actor) <- seed pool 900 1
    _ <- admit pool source "parent-recovery"
    parent <- claimOne pool
    first <- withDb pool (admitTask parent message actor "same-child" "work" Research (object []) Map.empty)
    void $ withDb pool $ execute "UPDATE task_attempts SET lease_until=now()-interval '1 second' WHERE turn_id=?" (Only parent.atrTurnId)
    resumed <- claimOne pool
    second <- withDb pool (admitTask resumed message actor "same-child" "work" Research (object []) Map.empty)
    identifierOf first `shouldBe` identifierOf second

  it "allows only a current parent to steer its direct child" $ do
    source@(_, message, actor) <- seed pool 900 1
    root <- admit pool source "parent-steer"
    parent <- claimOne pool
    child <- withDb pool (admitTask parent message actor "child" "work" Research (object []) Map.empty)
    accepted <- withDb pool (steerChild parent.atrTurnId (identifierOf child) "check the evidence")
    hasError accepted `shouldBe` False
    denied <- withDb pool (steerChild parent.atrTurnId root "steer the owner")
    hasError denied `shouldBe` True
    withDb pool (finishAgentTurn parent TurnFailed 0 Nothing Nothing)
    late <- withDb pool (steerChild parent.atrTurnId (identifierOf child) "late input")
    hasError late `shouldBe` True

  it "requires a report, not prose or normal agent termination, for success" $ do
    source <- seed pool 900 1
    identifier <- admit pool source "no-report"
    execution <- claimOne pool
    withDb pool (finishAgentTurn execution TurnSucceeded 1 Nothing Nothing)
    status pool identifier `shouldReturn` "failed"

  it "serializes shared sandbox ownership by task rather than conversation" $ do
    first <- seed pool 900 1
    second <- seed pool 900 2
    _ <- admit pool first "resource-a"
    _ <- admit pool second "resource-b"
    left <- claimOne pool
    right <- claimOne pool
    void $
      withDb pool $
        execute
          "INSERT INTO sandboxes(conversation_id,sandbox_handle,container_name,volume_name,image,network_mode,status)\
          \ SELECT conversation_id,handle,handle,handle,'test-image','none','active' FROM conversations CROSS JOIN (VALUES ('s1'),('s2')) handles(handle) WHERE legacy_group_id=900"
          ()
    withDb pool (taskResource left.atrTurnId "s1") `shouldReturn` True
    withDb pool (taskResource right.atrTurnId "s1") `shouldReturn` False
    withDb pool (taskResource right.atrTurnId "s2") `shouldReturn` True
    withDb pool (taskResource right.atrTurnId "s999") `shouldReturn` False
    withDb pool (finishAgentTurn left TurnFailed 0 (Just "stopped") Nothing)
    withDb pool (taskResource right.atrTurnId "s1") `shouldReturn` True

  it "keeps result notification admission unique and stale generations unpublishable" $ do
    source@(_, _, actor) <- seed pool 900 1
    identifier <- admit pool source "notification"
    execution <- claimOne pool
    withDb pool (taskReport execution.atrTurnId success) `shouldReturn` True
    withDb pool (finishAgentTurn execution TurnSucceeded 1 Nothing Nothing)
    (firstClaim, secondClaim) <- concurrently (withDb pool admitTaskNotification) (withDb pool admitTaskNotification)
    notification <- case firstClaim <> secondClaim of
      [claimed] -> pure claimed
      other -> expectationFailure ("expected one notification, got " <> show other) >> fail "notification claim"
    length (firstClaim <> secondClaim) `shouldBe` 1
    withDb pool admitTaskNotification `shouldReturn` []
    Just frontend <- withDb pool (taskTurnRef notification)
    withDb pool (claimFrontend frontend) `shouldReturn` True
    _ <- withDb pool (taskControl (GroupId 900) actor False identifier "replace" (Just 1) Nothing "new specification")
    withDb pool (authorizeTaskStep notification (Just "task_finish") False) `shouldReturn` False
    withDb pool (enqueueOutbound (draft frontend)) `shouldThrow` anyException

  it "resolves the source obligation only after the coordinated report is recorded" $ do
    source@(_, message, _) <- seed pool 900 1
    _ <- admit pool source "publication-obligation"
    execution <- claimOne pool
    withDb pool (taskReport execution.atrTurnId success) `shouldReturn` True
    withDb pool (finishAgentTurn execution TurnSucceeded 1 Nothing Nothing)
    [notification] <- withDb pool admitTaskNotification
    Just frontend <- withDb pool (taskTurnRef notification)
    withDb pool (claimFrontend frontend) `shouldReturn` True
    beforePublication <- withDb pool $ query "SELECT disposition FROM conversation_requests WHERE message_id=?" (Only message.unCanonicalMessageId)
    beforePublication `shouldBe` [Only ("delegated" :: Text)]
    void $ withDb pool (enqueueOutbound (draft frontend))
    withDb pool (finishAgentTurn frontend TurnSucceeded 1 Nothing Nothing)
    afterPublication <- withDb pool $ query "SELECT disposition FROM conversation_requests WHERE message_id=?" (Only message.unCanonicalMessageId)
    afterPublication `shouldBe` [Only ("answered" :: Text)]

  it "retains task reply provenance after a notification retry" $ do
    source <- seed pool 900 1
    identifier <- admit pool source "reply-provenance"
    execution <- claimOne pool
    withDb pool (taskReport execution.atrTurnId success) `shouldReturn` True
    withDb pool (finishAgentTurn execution TurnSucceeded 1 Nothing Nothing)
    [notification] <- withDb pool admitTaskNotification
    Just frontend <- withDb pool (taskTurnRef notification)
    withDb pool (claimFrontend frontend) `shouldReturn` True
    publication <- withDb pool (enqueueOutbound (draft frontend))
    withDb pool (finishAgentTurn frontend TurnFailed 0 Nothing Nothing)
    withDb pool admitTaskNotification `shouldReturn` []
    void $ withDb pool $ execute "UPDATE task_notifications SET next_attempt_at=now() - interval '1 second'" ()
    [_] <- withDb pool admitTaskNotification
    withDb pool (taskForReply (GroupId 900) publication.canonicalMessageId) `shouldReturn` Just identifier

  it "exposes a bounded admin projection for durable tasks, monitors and obligations" $ do
    source <- seed pool 900 1
    _ <- admit pool source "admin"
    overview <- withDb pool durableWorkOverview
    hasError overview `shouldBe` False

  it "delivers a completed child to its waiting parent, not the room" $ do
    source@(_, message, actor) <- seed pool 900 1
    identifier <- admit pool source "parent"
    parent <- claimOne pool
    _ <- withDb pool (admitTask parent message actor "child" "child work" Research (object []) Map.empty)
    withDb pool (taskReport parent.atrTurnId success) `shouldReturn` False
    withDb pool (taskReport parent.atrTurnId (report "waiting")) `shouldReturn` True
    withDb pool (finishAgentTurn parent TurnSucceeded 1 Nothing Nothing)
    child <- claimOne pool
    withDb pool (taskReport child.atrTurnId success) `shouldReturn` True
    withDb pool (finishAgentTurn child TurnSucceeded 1 Nothing Nothing)
    status pool identifier `shouldReturn` "queued"
    rows <- withDb pool $ query "SELECT kind FROM task_events WHERE task_id=?" (Only identifier)
    rows `shouldBe` [Only ("child_result" :: Text)]

  it "admits each monitor occurrence as one task, never a legacy turn as well" $ do
    source@(turn, seedMessage, actor) <- seed pool 900 1
    now <- getCurrentTime
    Right _ <- withDb pool (armElaboratedTimeMonitor (GroupId 900) actor turn "watch" Nothing (addUTCTime (-1) now) Map.empty)
    void $ withDb pool (admitDueTimeMonitors now)
    [fire] <- withDb pool (claimElaboratedMonitorFires "monitor-test" now 60 10)
    first <- withDb pool (admitMonitorTask "monitor-test" fire.emfFireId Nothing Map.empty seedMessage)
    second <- withDb pool (admitMonitorTask "monitor-test" fire.emfFireId Nothing Map.empty seedMessage)
    first `shouldBe` second
    rows <- withDb pool $ query "SELECT admitted_turn_id,task_id IS NOT NULL FROM monitor_fires WHERE fire_id=?" (Only fire.emfFireId)
    rows `shouldBe` [(Nothing :: Maybe Int64, True)]
    _ <- admit pool source "foreground-separate"
    pure ()

  it "preserves monitor snapshots across revision changes and explicit pending retention" $ do
    (turn, _, actor) <- seed pool 900 1
    now <- getCurrentTime
    Right monitor <- withDb pool (armLedgerMatchMonitor (GroupId 900) actor turn "old goal" (LedgerMatchSpec Nothing (Just "match") Nothing False) 0 (addUTCTime 86400 now) 20 Map.empty)
    insertOccurrence pool monitor "before"
    changed <- withDb pool (monitorControl (GroupId 900) actor False monitor.mrMonitorOrdinal.unMonitorOrdinal "configure" (Just 1) "new goal" "coalesce" 8 "retain" False)
    hasError changed `shouldBe` False
    rows <- withDb pool $ query "SELECT definition_revision,definition_snapshot->>'goal',cancelled_at IS NULL FROM monitor_fires" ()
    rows `shouldBe` [(1 :: Int, "old goal" :: Text, True)]

  it "keeps elaborated monitors single-flight while retaining one coalesced activation" $ do
    (turn, seedMessage, actor) <- seed pool 900 1
    now <- getCurrentTime
    Right monitor <- withDb pool (armLedgerMatchMonitor (GroupId 900) actor turn "watch" (LedgerMatchSpec Nothing (Just "match") Nothing False) 0 (addUTCTime 86400 now) 20 Map.empty)
    insertOccurrence pool monitor "first"
    [first] <- withDb pool (claimElaboratedMonitorFires "monitor-test" now 60 10)
    _ <- withDb pool (admitMonitorTask "monitor-test" first.emfFireId Nothing Map.empty seedMessage)
    active <- claimOne pool
    insertOccurrence pool monitor "pending"
    [second] <- withDb pool (claimElaboratedMonitorFires "monitor-test" now 60 10)
    _ <- withDb pool (admitMonitorTask "monitor-test" second.emfFireId Nothing Map.empty seedMessage)
    insertOccurrence pool monitor "coalesced"
    withDb pool (claimTask "task-test") `shouldReturn` []
    withDb pool (taskReport active.atrTurnId success) `shouldReturn` True
    withDb pool (finishAgentTurn active TurnSucceeded 1 Nothing Nothing)
    _ <- claimOne pool
    rows <- withDb pool $ query "SELECT disposition FROM monitor_fires ORDER BY fire_id" ()
    rows `shouldBe` map Only (["task", "task", "coalesced"] :: [Text])

  it "records coalescing and bounded queue overflow without deleting occurrences" $ do
    (turn, _, actor) <- seed pool 900 1
    now <- getCurrentTime
    Right monitor <- withDb pool (armLedgerMatchMonitor (GroupId 900) actor turn "watch" (LedgerMatchSpec Nothing (Just "match") Nothing False) 0 (addUTCTime 86400 now) 20 Map.empty)
    insertOccurrence pool monitor "first"
    insertOccurrence pool monitor "coalesced"
    _ <- withDb pool (monitorControl (GroupId 900) actor False monitor.mrMonitorOrdinal.unMonitorOrdinal "configure" (Just 1) "watch every" "queue" 1 "cancel" False)
    insertOccurrence pool monitor "second-revision"
    insertOccurrence pool monitor "overflow"
    rows <- withDb pool $ query "SELECT disposition FROM monitor_fires ORDER BY fire_id" ()
    rows `shouldBe` map Only (["cancelled", "coalesced", "pending", "overflow"] :: [Text])

  it "notifies when a monitor changes back to an earlier result, but not unchanged results" $ do
    (turn, seedMessage, actor) <- seed pool 900 1
    now <- getCurrentTime
    Right monitor <- withDb pool (armLedgerMatchMonitor (GroupId 900) actor turn "watch" (LedgerMatchSpec Nothing (Just "match") Nothing False) 0 (addUTCTime 86400 now) 20 Map.empty)
    let changed = object ["status" .= ("succeeded" :: Text), "summary" .= ("different findings" :: Text)]
    finishOccurrence pool monitor seedMessage "first" success
    finishOccurrence pool monitor seedMessage "unchanged" success
    finishOccurrence pool monitor seedMessage "changed" changed
    finishOccurrence pool monitor seedMessage "returned" success
    rows <- withDb pool $ query "SELECT count(*) FROM task_notifications" ()
    rows `shouldBe` [Only (3 :: Int64)]

  it "throttles monitor failures from the last notification, not the last suppressed failure" $ do
    (turn, seedMessage, actor) <- seed pool 900 1
    now <- getCurrentTime
    Right monitor <- withDb pool (armLedgerMatchMonitor (GroupId 900) actor turn "watch" (LedgerMatchSpec Nothing (Just "match") Nothing False) 0 (addUTCTime 86400 now) 20 Map.empty)
    finishOccurrence pool monitor seedMessage "first" (report "failed")
    finishOccurrence pool monitor seedMessage "suppressed" (report "failed")
    rows <- withDb pool $ query "SELECT count(*) FROM task_notifications" ()
    rows `shouldBe` [Only (1 :: Int64)]
    void $ withDb pool $ execute "UPDATE durable_tasks SET updated_at=now()-interval '2 hours' WHERE task_id IN (SELECT task_id FROM task_notifications)" ()
    finishOccurrence pool monitor seedMessage "next-hour" (report "failed")
    later <- withDb pool $ query "SELECT count(*) FROM task_notifications" ()
    later `shouldBe` [Only (2 :: Int64)]

  it "advances cron after queue overflow without admitting an extra task" $ do
    (turn, seedMessage, actor) <- seed pool 900 1
    [Only now] <- withDb pool $ query "SELECT clock_timestamp()" ()
    Right monitor <- withDb pool (armElaboratedTimeMonitor (GroupId 900) actor turn "watch" (Just "* * * * *") now Map.empty)
    _ <- withDb pool (monitorControl (GroupId 900) actor False monitor.mrMonitorOrdinal.unMonitorOrdinal "configure" (Just 1) "watch" "queue" 1 "retain" False)
    insertOccurrence pool monitor "pending"
    insertOccurrence pool monitor "overflow"
    fires <- withDb pool (claimElaboratedMonitorFires "monitor-test" now 60 10)
    length fires `shouldBe` 2
    let next = addUTCTime 60 now
    mapM_ (\fire -> withDb pool (admitMonitorTask "monitor-test" fire.emfFireId (Just next) Map.empty seedMessage)) fires
    rows <- withDb pool $ query "SELECT disposition,admission_state,task_id IS NULL FROM monitor_fires ORDER BY fire_id" ()
    rows `shouldBe` [("task" :: Text, "dispatched" :: Text, False), ("overflow", "dispatched", True)]
    deadlines <- withDb pool $ query "SELECT next_fire_at FROM monitors" ()
    deadlines `shouldBe` [Only (Just next)]

  it "requires an administrator when a legacy monitor has no owning principal" $ do
    (turn, _, actor) <- seed pool 900 1
    now <- getCurrentTime
    Right monitor <- withDb pool (armElaboratedTimeMonitor (GroupId 900) actor turn "watch" Nothing now Map.empty)
    void $ withDb pool $ execute "UPDATE monitors SET armed_by_principal_id=NULL WHERE monitor_id=?" (Only monitor.mrMonitorId)
    denied <- withDb pool (monitorControl (GroupId 900) actor False monitor.mrMonitorOrdinal.unMonitorOrdinal "cancel" Nothing "" "coalesce" 8 "cancel" False)
    hasError denied `shouldBe` True
    allowed <- withDb pool (monitorControl (GroupId 900) actor True monitor.mrMonitorOrdinal.unMonitorOrdinal "cancel" Nothing "" "coalesce" 8 "cancel" False)
    hasError allowed `shouldBe` False

  it "cancels future monitor work separately from already admitted tasks" $ do
    (turn, seedMessage, actor) <- seed pool 900 1
    now <- getCurrentTime
    Right monitor <- withDb pool (armElaboratedTimeMonitor (GroupId 900) actor turn "watch" Nothing (addUTCTime (-1) now) Map.empty)
    void $ withDb pool (admitDueTimeMonitors now)
    [fire] <- withDb pool (claimElaboratedMonitorFires "monitor-test" now 60 10)
    admitted <- withDb pool (admitMonitorTask "monitor-test" fire.emfFireId Nothing Map.empty seedMessage)
    let identifier = identifierOf admitted
    _ <- withDb pool (monitorControl (GroupId 900) actor False monitor.mrMonitorOrdinal.unMonitorOrdinal "cancel" Nothing "" "coalesce" 8 "cancel" False)
    status pool identifier `shouldReturn` "queued"
    _ <- withDb pool (monitorControl (GroupId 900) actor False monitor.mrMonitorOrdinal.unMonitorOrdinal "cancel" Nothing "" "coalesce" 8 "cancel" True)
    status pool identifier `shouldReturn` "cancelled"


  it "uses fivefold task quotas without granting extra authority" $ do
    source <- seed pool 900 1
    identifier <- admit pool source "limits"
    rows <- withDb pool $ query "SELECT max_calls,max_rounds,extract(epoch FROM deadline-created_at)::integer,grants::text FROM durable_tasks WHERE task_id=?" (Only identifier)
    rows `shouldBe` [(200 :: Int, 400 :: Int, 3000 :: Int, "{}" :: Text)]

  it "persists retry backoff and preserves reservations across attempts" $ do
    source <- seed pool 900 1
    identifier <- admit pool source "transient"
    first <- claimOne pool
    withDb pool (authorizeTaskStep first.atrTurnId (Just "web_search") True) `shouldReturn` True
    withDb pool (recordTaskFailure first.atrTurnId "HTTP 503 unavailable" True) `shouldReturn` True
    withDb pool (finishAgentTurn first TurnFailed 1 (Just "HTTP 503 unavailable") Nothing)
    status pool identifier `shouldReturn` "retrying"
    withDb pool (claimTask "too-early") `shouldReturn` []
    wakeMicros <- withDb pool nextTaskWakeMicros
    wakeMicros `shouldSatisfy` (\delay -> delay >= 50000 && delay <= 5000000)
    rows <- withDb pool $ query "SELECT retry_count,calls_reserved,next_attempt_at>now(),last_error FROM durable_tasks WHERE task_id=?" (Only identifier)
    rows `shouldBe` [(1 :: Int, 1 :: Int, True, "HTTP 503 unavailable" :: Text)]
    void $ withDb pool $ execute "UPDATE durable_tasks SET next_attempt_at=now()-interval '1 second' WHERE task_id=?" (Only identifier)
    second <- claimOne pool
    second `shouldNotBe` first
    counters <- withDb pool $ query "SELECT attempt,calls_reserved FROM durable_tasks WHERE task_id=?" (Only identifier)
    counters `shouldBe` [(2 :: Int, 1 :: Int)]
    withDb pool (recordTaskFailure first.atrTurnId "stale" True) `shouldReturn` False

  it "does not automatically retry ambiguous effects" $ do
    source <- seed pool 900 1
    identifier <- admit pool source "ambiguous"
    execution <- claimOne pool
    _ <- withDb pool (startJournalExecution execution (JournalStart "uncertain" "sandbox_exec" 1 "hash" (object []) (toJSON ([] :: [Text])) "retry-unsafe"))
    withDb pool (recordTaskFailure execution.atrTurnId "HTTP 503" True) `shouldReturn` True
    withDb pool (finishAgentTurn execution TurnFailed 1 Nothing Nothing)
    status pool identifier `shouldReturn` "waiting"
    withDb pool (claimTask "no-replay") `shouldReturn` []

  it "does not retry permanent failures" $ do
    source <- seed pool 900 1
    identifier <- admit pool source "permanent"
    execution <- claimOne pool
    withDb pool (recordTaskFailure execution.atrTurnId "HTTP 403" False) `shouldReturn` True
    withDb pool (finishAgentTurn execution TurnFailed 1 Nothing Nothing)
    status pool identifier `shouldReturn` "failed"

  it "coalesces durable progress, preserves its latest version, and fences old attempts" $ do
    source@(_, _, actor) <- seed pool 900 1
    identifier <- admit pool source "progress"
    execution <- claimOne pool
    let progress body = object ["summary" .= (body :: Text)]
    withDb pool (recordTaskProgress execution.atrTurnId (progress "first")) `shouldReturn` True
    withDb pool (recordTaskProgress execution.atrTurnId (progress "first")) `shouldReturn` True
    withDb pool (recordTaskProgress execution.atrTurnId (progress "second")) `shouldReturn` True
    rows <- withDb pool $ query "SELECT version,body->>'summary',(SELECT count(*) FROM task_notifications WHERE task_id=progress.task_id) FROM task_progress progress WHERE task_id=?" (Only identifier)
    rows `shouldBe` [(2 :: Int64, "second" :: Text, 1 :: Int64)]
    [notification] <- withDb pool admitTaskNotification
    Just frontend <- withDb pool (taskTurnRef notification)
    withDb pool (claimFrontend frontend) `shouldReturn` True
    void $ withDb pool (taskControl (GroupId 900) actor False identifier "replace" (Just 1) Nothing "new objective")
    withDb pool (recordTaskProgress execution.atrTurnId (progress "too late")) `shouldReturn` False
    withDb pool (authorizeTaskStep notification (Just "output") False) `shouldReturn` False
    withDb pool (loadTaskNotification notification) `shouldReturn` Nothing

  it "supersedes pending progress without suppressing the final result" $ do
    source <- seed pool 900 1
    identifier <- admit pool source "progress-result"
    execution <- claimOne pool
    withDb pool (recordTaskProgress execution.atrTurnId (object ["summary" .= ("working" :: Text)])) `shouldReturn` True
    withDb pool (taskReport execution.atrTurnId success) `shouldReturn` True
    withDb pool (finishAgentTurn execution TurnSucceeded 1 Nothing Nothing)
    rows <- withDb pool $ query "SELECT kind,superseded_at IS NOT NULL FROM task_notifications WHERE task_id=? ORDER BY notification_id" (Only identifier)
    rows `shouldBe` [("progress" :: Text, True), ("result", False)]
    [notification] <- withDb pool admitTaskNotification
    withDb pool (notificationKind notification) `shouldReturn` Just "result"

  it "routes child progress to the parent inbox without waking or reporting to the room" $ do
    source@(_, message, actor) <- seed pool 900 1
    identifier <- admit pool source "parent-progress"
    parent <- claimOne pool
    void $ withDb pool (admitTask parent message actor "child" "child work" Research (object []) Map.empty)
    withDb pool (taskReport parent.atrTurnId (report "waiting")) `shouldReturn` True
    withDb pool (finishAgentTurn parent TurnSucceeded 1 Nothing Nothing)
    child <- claimOne pool
    withDb pool (recordTaskProgress child.atrTurnId (object ["summary" .= ("working" :: Text)])) `shouldReturn` True
    status pool identifier `shouldReturn` "waiting"
    events <- withDb pool $ query "SELECT kind FROM task_events WHERE task_id=?" (Only identifier)
    events `shouldSatisfy` elem (Only ("child_progress" :: Text))
    withDb pool admitTaskNotification `shouldReturn` []

  for_ ["answered", "waiting", "declined"] $ \disposition ->
    it ("records explicit frontend disposition only after output: " <> show disposition) $ do
      (frontend, message, _) <- seed pool 900 1
      withDb pool (claimFrontend frontend) `shouldReturn` True
      withDb pool (finishRequest frontend.atrTurnId disposition "visible reply") `shouldReturn` True
      void $ withDb pool (enqueueOutbound (draft frontend))
      withDb pool (finishAgentTurn frontend TurnSucceeded 1 Nothing Nothing)
      rows <- withDb pool $ query "SELECT disposition FROM conversation_requests WHERE message_id=?" (Only message.unCanonicalMessageId)
      rows `shouldBe` [Only disposition]

  it "does not count a successful turn without an output receipt as an answered request" $ do
    (frontend, message, _) <- seed pool 900 1
    withDb pool (claimFrontend frontend) `shouldReturn` True
    withDb pool (finishRequest frontend.atrTurnId "answered" "not sent") `shouldReturn` True
    withDb pool (finishAgentTurn frontend TurnSucceeded 1 Nothing Nothing)
    rows <- withDb pool $ query "SELECT disposition FROM conversation_requests WHERE message_id=?" (Only message.unCanonicalMessageId)
    rows `shouldBe` [Only ("failed" :: Text)]

  it "keeps unclassified prose unresolved instead of inferring success" $ do
    (frontend, message, _) <- seed pool 900 1
    withDb pool (claimFrontend frontend) `shouldReturn` True
    void $ withDb pool (enqueueOutbound (draft frontend))
    withDb pool (finishAgentTurn frontend TurnSucceeded 1 Nothing Nothing)
    rows <- withDb pool $ query "SELECT disposition FROM conversation_requests WHERE message_id=?" (Only message.unCanonicalMessageId)
    rows `shouldBe` [Only ("waiting" :: Text)]

  it "snapshots monitor profiles and change policy under the definition CAS" $ do
    (turn, _, actor) <- seed pool 900 1
    now <- getCurrentTime
    Right monitor <- withDb pool (armLedgerMatchMonitor (GroupId 900) actor turn "watch" (LedgerMatchSpec Nothing (Just "match") Nothing False) 0 (addUTCTime 86400 now) 100 Map.empty)
    changed <- withDb pool (configureMonitor (GroupId 900) actor False monitor.mrMonitorOrdinal.unMonitorOrdinal 1 "browser watch" "queue" 160 "retain" "browser" True)
    hasError changed `shouldBe` False
    insertOccurrence pool monitor "browser"
    stale <- withDb pool (configureMonitor (GroupId 900) actor False monitor.mrMonitorOrdinal.unMonitorOrdinal 1 "stale" "queue" 160 "retain" "sandbox" False)
    hasError stale `shouldBe` True
    rows <- withDb pool $ query "SELECT definition_revision,definition_snapshot->>'profile' FROM monitor_fires" ()
    rows `shouldBe` [(2 :: Int, "browser" :: Text)]

  it "compares stable monitor observations rather than generated wording" $ do
    (turn, seedMessage, actor) <- seed pool 900 1
    now <- getCurrentTime
    Right monitor <- withDb pool (armLedgerMatchMonitor (GroupId 900) actor turn "watch" (LedgerMatchSpec Nothing (Just "match") Nothing False) 0 (addUTCTime 86400 now) 100 Map.empty)
    let observation summary value = object ["status" .= ("succeeded" :: Text), "summary" .= (summary :: Text), "observation" .= (value :: Int)]
    finishOccurrence pool monitor seedMessage "first" (observation "first wording" 1)
    finishOccurrence pool monitor seedMessage "same" (observation "different wording" 1)
    finishOccurrence pool monitor seedMessage "changed" (observation "same wording" 2)
    rows <- withDb pool $ query "SELECT count(*) FROM task_notifications WHERE kind='result'" ()
    rows `shouldBe` [Only (2 :: Int64)]


  it "keeps progress publication separate from the source obligation" $ do
    source@(_, message, _) <- seed pool 900 1
    _ <- admit pool source "visible-progress"
    execution <- claimOne pool
    withDb pool (recordTaskProgress execution.atrTurnId (object ["summary" .= ("working" :: Text)])) `shouldReturn` True
    [notification] <- withDb pool admitTaskNotification
    Just frontend <- withDb pool (taskTurnRef notification)
    withDb pool (claimFrontend frontend) `shouldReturn` True
    void $ withDb pool (enqueueOutbound (draft frontend))
    withDb pool (finishAgentTurn frontend TurnSucceeded 1 Nothing Nothing)
    rows <- withDb pool $ query "SELECT disposition FROM conversation_requests WHERE message_id=?" (Only message.unCanonicalMessageId)
    rows `shouldBe` [Only ("delegated" :: Text)]
    withDb pool (recordTaskProgress execution.atrTurnId (object ["summary" .= ("next step" :: Text)])) `shouldReturn` True
    withDb pool admitTaskNotification `shouldReturn` []
    wakeMicros <- withDb pool nextTaskWakeMicros
    wakeMicros `shouldSatisfy` (\delay -> delay > 0 && delay <= 30000000)

  it "does not retry after the shared tool budget is exhausted" $ do
    source <- seed pool 900 1
    identifier <- admit pool source "retry-budget"
    execution <- claimOne pool
    void $ withDb pool $ execute "UPDATE durable_tasks SET calls_reserved=max_calls WHERE task_id=?" (Only identifier)
    withDb pool (recordTaskFailure execution.atrTurnId "HTTP 503" True) `shouldReturn` True
    withDb pool (finishAgentTurn execution TurnFailed 1 Nothing Nothing)
    status pool identifier `shouldReturn` "failed"
    withDb pool (claimTask "spent") `shouldReturn` []

  it "retains backoff when feedback arrives during a retry" $ do
    source@(_, _, actor) <- seed pool 900 1
    identifier <- admit pool source "retry-feedback"
    execution <- claimOne pool
    withDb pool (recordTaskFailure execution.atrTurnId "HTTP 503" True) `shouldReturn` True
    withDb pool (finishAgentTurn execution TurnFailed 1 Nothing Nothing)
    void $ withDb pool (taskControl (GroupId 900) actor False identifier "steer" Nothing Nothing "extra evidence")
    status pool identifier `shouldReturn` "retrying"
    withDb pool (claimTask "still-too-early") `shouldReturn` []

  it "keeps an old occurrence's change-only policy after monitor configuration" $ do
    (turn, seedMessage, actor) <- seed pool 900 1
    now <- getCurrentTime
    Right monitor <- withDb pool (armLedgerMatchMonitor (GroupId 900) actor turn "watch" (LedgerMatchSpec Nothing (Just "match") Nothing False) 0 (addUTCTime 86400 now) 100 Map.empty)
    finishOccurrence pool monitor seedMessage "first" success
    insertOccurrence pool monitor "old-pending"
    changed <- withDb pool (configureMonitor (GroupId 900) actor False monitor.mrMonitorOrdinal.unMonitorOrdinal 1 "watch" "coalesce" 40 "retain" "research" False)
    hasError changed `shouldBe` False
    [fire] <- withDb pool (claimElaboratedMonitorFires "monitor-test" now 60 10)
    void $ withDb pool (admitMonitorTask "monitor-test" fire.emfFireId Nothing Map.empty seedMessage)
    execution <- claimOne pool
    withDb pool (taskReport execution.atrTurnId success) `shouldReturn` True
    withDb pool (finishAgentTurn execution TurnSucceeded 1 Nothing Nothing)
    rows <- withDb pool $ query "SELECT count(*) FROM task_notifications WHERE kind='result'" ()
    rows `shouldBe` [Only (1 :: Int64)]
    finishOccurrence pool monitor seedMessage "new-first" success
    finishOccurrence pool monitor seedMessage "new-same" success
    later <- withDb pool $ query "SELECT count(*) FROM task_notifications WHERE kind='result'" ()
    later `shouldBe` [Only (3 :: Int64)]

seed :: DbPool -> Int64 -> Int64 -> IO (AgentTurnRef, CanonicalMessageId, PrincipalId)
seed pool group user = do
  [Only count] <- withDb pool (query "SELECT count(*) FROM messages" ())
  message <- insertRawMessage pool (100000 + (count :: Int64)) group user 99 testTime Nothing "explicit request"
  [Only principal] <- withDb pool (query "SELECT author_principal_id FROM messages WHERE canonical_message_id=?" (Only message))
  turn <- withDb pool (startAgentTurn (GroupId group) (CanonicalMessageId message) (PrincipalId principal))
  pure (turn, CanonicalMessageId message, PrincipalId principal)

admit :: DbPool -> (AgentTurnRef, CanonicalMessageId, PrincipalId) -> Text -> IO Int64
admit pool (turn, message, actor) key = identifierOf <$> withDb pool (admitTask turn message actor key "bounded research" Research (object []) Map.empty)

identifierOf :: Value -> Int64
identifierOf (Object fields) = case KeyMap.lookup "task_id" fields >>= fromJSONValue of
  Just identifier -> identifier
  Nothing -> error (show fields)
identifierOf value = error (show value)

fromJSONValue :: (FromJSON value) => Value -> Maybe value
fromJSONValue value = case fromJSON value of Success decoded -> Just decoded; Error _ -> Nothing

hasError :: Value -> Bool
hasError (Object fields) = KeyMap.member "error" fields
hasError _ = True

claimOne :: DbPool -> IO AgentTurnRef
claimOne pool = do
  [identifier] <- withDb pool (claimTask "task-test")
  Just turn <- withDb pool (taskTurnRef identifier)
  pure turn

status :: DbPool -> Int64 -> IO Text
status pool identifier = do
  [Only value] <- withDb pool (query "SELECT status FROM durable_tasks WHERE task_id=?" (Only identifier))
  pure value

success :: Value
success = report "succeeded"

report :: Text -> Value
report state = object ["status" .= state, "summary" .= ("bounded findings" :: Text), "evidence" .= ([] :: [Text]), "unresolved" .= ([] :: [Text])]

finishOccurrence :: DbPool -> MonitorRef -> CanonicalMessageId -> Text -> Value -> IO ()
finishOccurrence pool monitor seedMessage key outcome = do
  insertOccurrence pool monitor key
  now <- getCurrentTime
  [fire] <- withDb pool (claimElaboratedMonitorFires "monitor-test" now 60 10)
  admitted <- withDb pool (admitMonitorTask "monitor-test" fire.emfFireId Nothing Map.empty seedMessage)
  hasError admitted `shouldBe` False
  execution <- claimOne pool
  withDb pool (taskReport execution.atrTurnId outcome) `shouldReturn` True
  withDb pool (finishAgentTurn execution TurnSucceeded 1 Nothing Nothing)

insertOccurrence :: DbPool -> MonitorRef -> Text -> IO ()
insertOccurrence pool monitor key =
  void $
    withDb pool $
      execute
        "INSERT INTO monitor_fires(monitor_id,conversation_id,scheduled_at,idempotency_key) SELECT monitor_id,conversation_id,now(),? FROM monitors WHERE monitor_id=?"
        (key, monitor.mrMonitorId)

draft :: AgentTurnRef -> OutboundDraft
draft turn =
  OutboundDraft
    { legacyConversationId = 900,
      transcriptKind = "chat",
      sourceCanonicalMessageId = Nothing,
      canonicalBody = Body [NText "task report"],
      replyToCanonicalMessageId = Nothing,
      turnOutputLink = Just (TurnOutputLink turn.atrTurnId 0),
      monitorFireId = Nothing
    }

healthCount :: DbPool -> String -> IO Int64
healthCount pool label = case [sql | (name, _, sql) <- operationalChecks, name == label] of
  [sql] -> do
    [Only count] <- withDb pool $ query sql ()
    pure count
  _ -> fail ("missing health check: " <> label)
