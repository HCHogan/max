module Max.DB.TaskSpec (spec, seed, admit, claimOne, report, insertOccurrence, draft) where

import Control.Concurrent.Async (concurrently, mapConcurrently)
import Control.Exception (bracket_)
import Control.Monad (void)
import Data.Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Foldable (for_)
import Data.Int (Int64)
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Ord (Down (..))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (addUTCTime, getCurrentTime)
import Database.PostgreSQL.Simple (Only (..))
import Effectful.PostgreSQL (execute, query)
import Helpers (insertRawMessage, testTime, truncateAll, withDb, withDbLog)
import Max.Agent.Execution (ExecutionAdmission (..))
import Max.Agent.Runtime (durableExecutionAdmission)
import Max.Browser.State qualified as BrowserState
import Max.ConversationScope (conversationScopeFor)
import Max.DB.AgentTurn
import Max.DB.Connection (DbPool)
import Max.DB.Health (operationalChecks)
import Max.DB.Monitor
import Max.DB.Monitor.Occurrence (OccurrenceDraft (..), recordOccurrence)
import Max.DB.Task
import Max.DB.Task.Overview qualified as WorkQuery
import Max.DB.Task.Query qualified as TaskQuery
import Max.DB.Task.Progress (recordProgressDecision)
import Max.DB.Task.Record (databaseNow)
import Max.Effects.MonitorControl qualified as MonitorCapability
import Max.Effects.MonitorQuery qualified as MonitorQueryCapability
import Max.Effects.TaskControl qualified as ControlCapability
import Max.Effects.TaskExecution qualified as ExecutionCapability
import Max.Effects.ToolControl (runToolControl)
import Max.Effects.Tools (Tool (..))
import Max.Execution.Types (ExecutionStep (..), StepReservation (..))
import Max.IR (Body (..), Node (NText))
import Max.Monitor.Control qualified as MonitorControl
import Max.Monitor.Types
import Max.Platform.Store (EnqueuedOutbound (..), OutboundDraft (..), enqueueOutbound)
import Max.Platform.Types (CanonicalMessageId (..), PrincipalId (..), noAdvertisedCaps)
import Max.Task.Admission (AdmissionError (..))
import Max.Task.Admission qualified as Admission
import Max.Task.Execution (ExecutionFailure (..))
import Max.Task.Overview qualified as WorkView
import Max.Task.Policy (frontendDeadlineSeconds)
import Max.Task.Progress (ProgressDecision (PublishProgress))
import Max.Task.Query qualified as QueryView
import Max.Task.State (FailureKind (..), TaskControlError (TaskCallerFenced, TaskNotFound), TaskOperation (Cancel, Steer))
import Max.Task.State qualified as TaskState
import Max.Task.ToolRuntime (taskToolsWithDatabase)
import Max.Task.Types (TaskProfile (..), taskHandle)
import Max.Task.View (renderTaskHistory)
import Max.ToolContext
import Max.Turn.Types
import OneBot.Types (GroupId (..), UserId (..))
import Test.Hspec

spec :: DbPool -> Spec
spec pool = before_ (truncateAll pool) $ describe "ADR008 durable tasks" $ do
  it "uses explicit Haskell settlement without business cascade triggers" $ do
    rows <- withDb pool $ query "SELECT tgname FROM pg_trigger WHERE tgname IN ('task_attempt_settle','task_completion','browser_task_changed','monitor_fire_snapshot','zz_browser_fire_profile','browser_profile_changed')" ()
    (rows :: [Only Text]) `shouldBe` []

  it "reads typed, scoped task facts with nullable retry state and bounded event history" $ do
    source@(_, _, actor) <- seed pool 900 1
    identifier <- admit pool source "typed-detail"
    task <- withDb pool (TaskQuery.readTask (GroupId 900) identifier)
    case task of
      Just details -> do
        details.core.summary.taskId `shouldBe` identifier
        details.core.nextAttemptAt `shouldBe` Nothing
        details.browser `shouldBe` Nothing
        details.progress `shouldBe` Nothing
        details.usage `shouldBe` QueryView.TaskUsage 0 0
      Nothing -> expectationFailure "typed task detail missing"
    withDb pool (TaskQuery.readTask (GroupId 901) identifier) `shouldReturn` Nothing
    withDb pool (TaskQuery.listTasks (GroupId 901)) `shouldReturn` []
    for_ [1 .. 65 :: Int] $ \event -> do
      _ <- withDb pool (taskControl (GroupId 900) actor False identifier "steer" Nothing Nothing ("event " <> T.pack (show event)))
      pure ()
    detailed <- withDb pool (TaskQuery.readTask (GroupId 900) identifier)
    case detailed of
      Just details -> do
        length details.events `shouldBe` 60
        details.core.pendingEvents `shouldBe` 65
        let ids = map (.eventId) details.events
        ids `shouldBe` sortOn Down ids
      Nothing -> expectationFailure "task disappeared after events"

  it "renders completed task details from report, usage and workspace facts" $ do
    (turn, message, actor) <- seed pool 900 1
    admitted <- withDb pool (admitTaskReceipt turn message actor "rich-query" (T.replicate 2000 "x") Research (object []) Map.empty)
    identifier <- case admitted of
      Right (receipt :: Admission.TaskAdmissionReceipt) -> pure receipt.taskId
      Left failure -> fail (show failure)
    execution <- claimOne pool
    withDb pool (recordTaskProgress execution.atrTurnId (object ["summary" .= ("working" :: Text)])) `shouldReturn` True
    withDb pool (addAgentTurnUsage execution.atrTurnId 120 35 (Just 10))
    _ <- withDb pool $ execute "INSERT INTO browser_workspaces(task_id,revision) VALUES(?,1)" (Only identifier)
    withDb pool (taskReport execution.atrTurnId success) `shouldReturn` True
    withDb pool (finishAgentTurn execution TurnSucceeded 1 Nothing Nothing)
    detail <- withDb pool (TaskQuery.readTask (GroupId 900) identifier)
    case detail of
      Just details -> do
        T.length details.core.summary.objective `shouldBe` 2000
        details.core.summary.status `shouldBe` TaskState.Succeeded
        details.turns `shouldBe` [execution.atrTurnOrdinal.unTurnOrdinal]
        details.usage `shouldBe` QueryView.TaskUsage 120 35
        case details.browser of
          Just browser -> browser.state `shouldBe` BrowserState.Cold
          Nothing -> expectationFailure "workspace facts missing"
        case details.progress of
          Just progress -> progress.body `shouldBe` object ["status" .= ("running" :: Text), "summary" .= ("working" :: Text)]
          Nothing -> expectationFailure "progress facts missing"
        details.core.result `shouldSatisfy` maybe False (\case Object fields -> KeyMap.lookup "status" fields == Just (String "succeeded"); _ -> False)
      Nothing -> expectationFailure "completed task missing"
    summaries <- withDb pool (TaskQuery.listTasks (GroupId 900))
    case summaries of
      [summary] -> T.length summary.objective `shouldBe` 1500
      _ -> expectationFailure "bounded task summary missing"

  it "commits model admission and its round count in one transaction" $ do
    source <- seed pool 900 1
    identifier <- admit pool source "atomic-model-admission"
    execution <- claimOne pool
    let install = withDb pool $ do
          void $ execute "CREATE FUNCTION issue19_reject_round() RETURNS trigger LANGUAGE plpgsql AS 'BEGIN IF NEW.llm_turns>OLD.llm_turns THEN RAISE EXCEPTION ''injected round failure''; END IF; RETURN NEW; END'" ()
          void $ execute "CREATE TRIGGER issue19_reject_round BEFORE UPDATE ON agent_turns FOR EACH ROW EXECUTE FUNCTION issue19_reject_round()" ()
        remove = withDb pool $ do
          void $ execute "DROP TRIGGER issue19_reject_round ON agent_turns" ()
          void $ execute "DROP FUNCTION issue19_reject_round()" ()
    bracket_ install remove $
      withDb pool (durableExecutionAdmission.eaReserveRound execution) `shouldThrow` anyException
    reserved <- withDb pool $ query "SELECT rounds_reserved FROM durable_tasks WHERE task_id=?" (Only identifier)
    reserved `shouldBe` [Only (0 :: Int)]
    withDb pool (durableExecutionAdmission.eaReserveRound execution) `shouldReturn` True
    counts <- withDb pool $ query "SELECT work.rounds_reserved,turn.llm_turns FROM durable_tasks work JOIN task_attempts USING(task_id) JOIN agent_turns turn USING(turn_id) WHERE work.task_id=?" (Only identifier)
    counts `shouldBe` [(1 :: Int, 1 :: Int)]

  it "rolls back tool budget when the pre-effect journal cannot commit" $ do
    source <- seed pool 900 1
    identifier <- admit pool source "atomic-tool-admission"
    execution <- claimOne pool
    let start = JournalStart "call" "web_search" 1 "fixture" (object []) (toJSON ([] :: [Value])) "safe"
        install = withDb pool $ do
          void $ execute "CREATE FUNCTION issue19_reject_journal() RETURNS trigger LANGUAGE plpgsql AS 'BEGIN RAISE EXCEPTION ''injected journal failure''; END'" ()
          void $ execute "CREATE TRIGGER issue19_reject_journal BEFORE INSERT ON execution_journal FOR EACH ROW EXECUTE FUNCTION issue19_reject_journal()" ()
        remove = withDb pool $ do
          void $ execute "DROP TRIGGER issue19_reject_journal ON execution_journal" ()
          void $ execute "DROP FUNCTION issue19_reject_journal()" ()
        admitCall = withDb pool (durableExecutionAdmission.eaStartTool (GroupId 900) execution (ExecutionWork ReserveCall) start)
    bracket_ install remove $ admitCall `shouldThrow` anyException
    reserved <- withDb pool $ query "SELECT calls_reserved FROM durable_tasks WHERE task_id=?" (Only identifier)
    reserved `shouldBe` [Only (0 :: Int)]
    _ <- admitCall
    counts <- withDb pool $ query "SELECT work.calls_reserved,(SELECT count(*) FROM execution_journal WHERE turn_id=?) FROM durable_tasks work WHERE work.task_id=?" (execution.atrTurnId, identifier)
    counts `shouldBe` [(1 :: Int, 1 :: Int64)]

  it "rolls back the turn, task and notification when downstream settlement fails" $ do
    source <- seed pool 900 1
    identifier <- admit pool source "atomic-settle"
    execution <- claimOne pool
    withDb pool (taskReport execution.atrTurnId success) `shouldReturn` True
    let install = withDb pool $ do
          void $ execute "CREATE FUNCTION issue19_reject_notice() RETURNS trigger LANGUAGE plpgsql AS 'BEGIN RAISE EXCEPTION ''injected notification failure''; END'" ()
          void $ execute "CREATE TRIGGER issue19_reject_notice BEFORE INSERT ON task_notifications FOR EACH ROW EXECUTE FUNCTION issue19_reject_notice()" ()
        remove = withDb pool $ do
          void $ execute "DROP TRIGGER issue19_reject_notice ON task_notifications" ()
          void $ execute "DROP FUNCTION issue19_reject_notice()" ()
    bracket_ install remove $
      withDb pool (finishAgentTurn execution TurnSucceeded 1 Nothing Nothing) `shouldThrow` anyException
    states <- withDb pool $ query "SELECT work.status,turn.status FROM durable_tasks work JOIN task_attempts attempt USING(task_id) JOIN agent_turns turn USING(turn_id) WHERE work.task_id=?" (Only identifier)
    states `shouldBe` [("running" :: Text, "starting" :: Text)]
    withDb pool (finishAgentTurn execution TurnSucceeded 1 Nothing Nothing)
    withDb pool (finishAgentTurn execution TurnSucceeded 1 Nothing Nothing)
    notices <- withDb pool $ query "SELECT count(*) FROM task_notifications WHERE task_id=? AND kind='result'" (Only identifier)
    notices `shouldBe` [Only (1 :: Int64)]

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

  it "does not reveal an idempotent admission to a different actor" $ do
    source@(turn, message, _) <- seed pool 900 1
    (_, _, other) <- seed pool 900 2
    _ <- admit pool source "private-key"
    denied <- withDb pool (admitTask turn message other "private-key" "guess" Research (object []) Map.empty)
    hasError denied `shouldBe` True

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

  it "fences the task-control caller in the same transaction as its mutation" $ do
    source@(turn, message, actor) <- seed pool 900 1
    identifier <- admit pool source "caller-fence"
    let scope = ControlCapability.TaskControlScope (GroupId 900) (Just turn) message actor Map.empty False
        control note = withDb pool . ControlCapability.runTaskControl scope $ ControlCapability.controlTask identifier Steer Nothing note
    accepted <- control "before caller finishes"
    accepted `shouldSatisfy` either (const False) (const True)
    withDb pool (finishAgentTurn turn TurnSucceeded 0 Nothing Nothing)
    control "stale caller" `shouldReturn` Left TaskCallerFenced
    events <- withDb pool $ query "SELECT count(*) FROM task_events WHERE task_id=? AND body='stale caller'" (Only identifier)
    events `shouldBe` [Only (0 :: Int64)]

  it "binds task control to the caller's conversation" $ do
    (turn, message, actor) <- seed pool 900 1
    foreignSource <- seed pool 901 1
    identifier <- admit pool foreignSource "other-conversation"
    let scope = ControlCapability.TaskControlScope (GroupId 900) (Just turn) message actor Map.empty False
    rejected <- withDb pool . ControlCapability.runTaskControl scope $ ControlCapability.controlTask identifier Steer Nothing "guessed handle"
    rejected `shouldBe` Left TaskNotFound

  it "rechecks the bound caller identity against its current turn" $ do
    (turn, message, _) <- seed pool 900 1
    ownerSource@(_, _, owner) <- seed pool 900 2
    identifier <- admit pool ownerSource "other-owner"
    let forgedScope = ControlCapability.TaskControlScope (GroupId 900) (Just turn) message owner Map.empty False
    rejected <- withDb pool . ControlCapability.runTaskControl forgedScope $ ControlCapability.controlTask identifier Cancel Nothing "wrong caller"
    rejected `shouldBe` Left TaskCallerFenced

  it "takes admission authority from the bound scope rather than input JSON" $ do
    (turn, message, actor) <- seed pool 900 1
    let grants = Map.fromList [("web_search", "search-grant"), ("browser_navigate", "browser-grant")]
        scope = ControlCapability.TaskControlScope (GroupId 900) (Just turn) message actor grants False
    admitted <-
      withDb pool . ControlCapability.runTaskControl scope $
        ControlCapability.startTask "scoped-grants" "research" Research (object ["grants" .= Map.singleton ("poke" :: Text) ("invented" :: Text)])
    case admitted of
      Right (receipt :: Admission.TaskAdmissionReceipt) -> receipt.grants `shouldBe` Map.singleton "web_search" "search-grant"
      Left failure -> expectationFailure (show failure)

  it "requires a bound execution before accepting a report" $ do
    rejected <- withDb pool . ExecutionCapability.runTaskExecution Nothing $ ExecutionCapability.reportProgress "no owner"
    rejected `shouldBe` Left ExecutionContextMissing

  it "persists an operations profile with only the caller's existing maxops management grant" $ do
    (turn, message, actor) <- seed pool 900 1
    let grants = Map.fromList [("maxops_query", "query-grant"), ("maxops_execute", "management-grant"), ("sandbox_exec", "sandbox-grant")]
        scope = ControlCapability.TaskControlScope (GroupId 900) (Just turn) message actor grants False
    admitted <- withDb pool . ControlCapability.runTaskControl scope $
      ControlCapability.startTask "fleet-operation" "diagnose and verify" Operations (object [])
    case admitted of
      Right (receipt :: Admission.TaskAdmissionReceipt) -> do
        receipt.grants `shouldBe` Map.delete "sandbox_exec" grants
        rows <- withDb pool $ query "SELECT profile FROM durable_tasks WHERE task_id=?" (Only receipt.taskId)
        rows `shouldBe` [Only ("operations" :: Text)]
      Left failure -> expectationFailure (show failure)

  it "prevents a research parent from manufacturing management authority through an operations child" $ do
    source@(_, message, actor) <- seed pool 900 1
    _ <- admit pool source "research-parent"
    parent <- claimOne pool
    rejected <- withDb pool (admitTaskReceipt parent message actor "forged-operation" "restart" Operations (object []) (Map.singleton "maxops_execute" "invented"))
    rejected `shouldBe` Left AdmissionWidenedAuthority

  it "enforces the profile grant ceiling at task admission even without a parent" $ do
    (turn, message, actor) <- seed pool 900 1
    rejected <- withDb pool (admitTaskReceipt turn message actor "wider-profile" "research" Research (object []) (Map.singleton "browser_navigate" "browser-grant"))
    rejected `shouldBe` Left AdmissionWidenedAuthority
    tasks <- withDb pool $ query "SELECT count(*) FROM durable_tasks" ()
    tasks `shouldBe` [Only (0 :: Int64)]

  it "enforces frozen profile policy during monitor task admission" $ do
    (turn, message, actor) <- seed pool 900 1
    now <- getCurrentTime
    let grants = Map.singleton "browser_navigate" "browser-grant"
    Right monitor <- withDb pool (armLedgerMatchMonitor (GroupId 900) actor turn "watch" (LedgerMatchSpec Nothing (Just "match") Nothing False) 0 (addUTCTime 86400 now) 100 grants)
    insertOccurrence pool monitor "profile-ceiling"
    [fire] <- withDb pool (claimElaboratedMonitorFires "monitor-test" now 60 10)
    rejected <- withDb pool (admitMonitorTask "monitor-test" fire.emfFireId Nothing grants message)
    hasError rejected `shouldBe` True
    tasks <- withDb pool $ query "SELECT count(*) FROM durable_tasks" ()
    tasks `shouldBe` [Only (0 :: Int64)]
    linked <- withDb pool $ query "SELECT count(*) FROM monitor_fires WHERE task_id IS NOT NULL" ()
    linked `shouldBe` [Only (0 :: Int64)]

  it "admits browser and sandbox through task_start without an inline Plan schema" $ do
    (turn, message, actor) <- seed pool 900 1
    output <- newTurnOutputContext turn
    let invokeWith grants profile = do
          let toolContext =
                mkToolContext
                  (TurnIdentity (GroupId 900) message (UserId 1) (UserId 99) actor Nothing (Just output))
                  (TurnCapabilities True False False noAdvertisedCaps False grants Nothing False)
          withDbLog pool $ fmap fst . runToolControl $ case [tool | tool <- taskToolsWithDatabase toolContext, tool.toolName == "task_start"] of
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
    withDb pool (authorizeTaskStep background.atrTurnId (ExecutionWork ReserveCall)) `shouldReturn` True
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
    withDb pool (authorizeTaskStep first.atrTurnId ExecutionCheckpoint) `shouldReturn` False
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
    withDb pool (authorizeTaskStep execution.atrTurnId (ExecutionWork ReserveCall)) `shouldReturn` False
    withDb pool (taskReport execution.atrTurnId success) `shouldReturn` False
    withDb pool (isTaskTurn execution.atrTurnId) `shouldReturn` True
    withDb pool (loadTaskExecution execution.atrTurnId) `shouldReturn` Nothing
    withDb pool (finishAgentTurn execution TurnSucceeded 0 Nothing Nothing)
    status pool identifier `shouldReturn` "cancelled"

  it "replaces with CAS while preserving identity, revision history and spend" $ do
    source@(_, _, actor) <- seed pool 900 1
    identifier <- admit pool source "replace"
    old <- claimOne pool
    withDb pool (authorizeTaskStep old.atrTurnId (ExecutionWork ReserveCall)) `shouldReturn` True
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

  it "recovers expired execution with its original budget, unknown effects and model notes" $ do
    source <- seed pool 900 1
    identifier <- admit pool source "recover"
    first <- claimOne pool
    withDb pool (authorizeTaskStep first.atrTurnId (ExecutionWork ReserveCall)) `shouldReturn` True
    _ <- withDb pool (startJournalExecution first (JournalStart "first" "web_search" 1 "hash" (object []) (toJSON ([] :: [Text])) "retry-safe"))
    withDb pool (recordModelNote first "evidence noted before restart")
    void $ withDb pool $ execute "UPDATE task_attempts SET lease_until=now()-interval '1 second' WHERE turn_id=?" (Only first.atrTurnId)
    second <- claimOne pool
    second `shouldNotBe` first
    withDb pool (taskReport first.atrTurnId success) `shouldReturn` False
    rows <- withDb pool $ query "SELECT calls_reserved FROM durable_tasks WHERE task_id=?" (Only identifier)
    rows `shouldBe` [Only (1 :: Int)]
    journal <- withDb pool $ query "SELECT state FROM execution_journal WHERE turn_id=?" (Only first.atrTurnId)
    journal `shouldMatchList` [Only ("outcome-unknown" :: Text), Only "succeeded"]
    Just recovered <- withDb pool (loadTaskExecution second.atrTurnId)
    let history = renderTaskHistory recovered.teHistory
    history `shouldSatisfy` T.isInfixOf "web_search [outcome-unknown]"
    history `shouldSatisfy` T.isInfixOf "model_note [succeeded] evidence noted before restart"

  it "shares reservations across descendants under parallel requests" $ do
    source@(_, message, actor) <- seed pool 900 1
    identifier <- admit pool source "root-budget"
    parent <- claimOne pool
    child <- withDb pool (admitTask parent message actor "child" "child work" Research (object []) Map.empty)
    hasError child `shouldBe` False
    descendant <- claimOne pool
    void $ withDb pool $ execute "UPDATE durable_tasks SET max_calls=1 WHERE task_id=?" (Only identifier)
    answers <- mapConcurrently (\turn -> withDb pool (authorizeTaskStep turn.atrTurnId (ExecutionWork ReserveCall))) [parent, descendant]
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
    withDb pool (authorizeTaskStep notification ExecutionCheckpoint) `shouldReturn` False
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

  it "fences monitor mutations when the bound frontend lease expires" $ do
    (turn, _, actor) <- seed pool 900 1
    withDb pool (claimFrontend turn) `shouldReturn` True
    now <- getCurrentTime
    let scope = MonitorCapability.MonitorControlScope (GroupId 900) (Just turn) actor Map.empty False
        reminder = MonitorCapability.armMonitor (MonitorCapability.CannedReminder "reminder" Nothing (addUTCTime 60 now))
    Right monitor <- withDb pool (MonitorCapability.runMonitorControl scope reminder)
    void $ withDb pool (execute "UPDATE conversation_frontends SET lease_until=now()-interval '1 second' WHERE turn_id=?" (Only turn.atrTurnId))
    withDb pool (MonitorCapability.runMonitorControl scope reminder) `shouldReturn` Left MonitorControl.ArmingCallerFenced
    withDb pool (MonitorCapability.runMonitorControl scope (MonitorCapability.controlMonitor monitor.mrMonitorOrdinal MonitorControl.CancelMonitor False)) `shouldReturn` Left MonitorControl.MonitorCallerFenced
    rows <- withDb pool (query "SELECT status FROM monitors" ())
    rows `shouldBe` [Only ("armed" :: Text)]

  it "binds monitor identity, role and query scope outside tool arguments" $ do
    (turn, _, actor) <- seed pool 900 1
    (_, _, otherActor) <- seed pool 901 2
    withDb pool (claimFrontend turn) `shouldReturn` True
    now <- getCurrentTime
    let scope = MonitorCapability.MonitorControlScope (GroupId 900) (Just turn) actor (Map.singleton "context_search" "frozen") False
        reminder = MonitorCapability.armMonitor (MonitorCapability.CannedReminder "reminder" Nothing (addUTCTime 60 now))
        elaborated = MonitorCapability.armMonitor (MonitorCapability.TimeMonitor "watch" Nothing (addUTCTime 60 now))
    withDb pool (MonitorCapability.runMonitorControl (scope {MonitorCapability.principal = otherActor}) reminder) `shouldReturn` Left MonitorControl.ArmingCallerFenced
    withDb pool (MonitorCapability.runMonitorControl (scope {MonitorCapability.group = GroupId 901}) reminder) `shouldReturn` Left MonitorControl.ArmingCallerFenced
    withDb pool (MonitorCapability.runMonitorControl scope elaborated) `shouldReturn` Left MonitorControl.MonitorArmingForbidden
    Right monitor <- withDb pool (MonitorCapability.runMonitorControl (scope {MonitorCapability.armingAllowed = True}) elaborated)
    grants <- withDb pool (query "SELECT effect_ceiling->'tool_grants' FROM monitors WHERE monitor_id=?" (Only monitor.mrMonitorId))
    grants `shouldBe` [Only (object ["context_search" .= ("frozen" :: Text)])]
    withDb pool (MonitorQueryCapability.runMonitorQuery (conversationScopeFor (GroupId 901)) (MonitorQueryCapability.readMonitorHistory monitor.mrMonitorOrdinal)) `shouldReturn` Nothing
    cancelled <- withDb pool (MonitorCapability.runMonitorControl scope (MonitorCapability.controlMonitor monitor.mrMonitorOrdinal MonitorControl.CancelMonitor False))
    cancelled `shouldSatisfy` either (const False) (const True)

  it "reads scoped, bounded monitor history as typed facts" $ do
    (turn, _, actor) <- seed pool 900 1
    now <- getCurrentTime
    Right monitor <- withDb pool (armLedgerMatchMonitor (GroupId 900) actor turn "watch" (LedgerMatchSpec Nothing (Just "match") Nothing False) 0 (addUTCTime 86400 now) 100 Map.empty)
    for_ [1 .. 155 :: Int] $ \index -> insertOccurrence pool monitor (T.pack (show index))
    void $ withDb pool (execute "UPDATE monitor_fires SET trigger_evidence=? WHERE monitor_id=?" (T.replicate 6000 "x", monitor.mrMonitorId))
    Just history <- withDb pool (WorkQuery.readMonitorHistory (GroupId 900) monitor.mrMonitorOrdinal.unMonitorOrdinal)
    history.definition.goal `shouldBe` "watch"
    history.definition.status `shouldBe` WorkView.Armed
    length history.fires `shouldBe` 150
    map (.fireId) history.fires `shouldBe` map (.fireId) (sortOn (Down . (.fireId)) history.fires)
    map (T.length . (.evidence)) history.fires `shouldBe` replicate 150 5000
    withDb pool (WorkQuery.readMonitorHistory (GroupId 901) monitor.mrMonitorOrdinal.unMonitorOrdinal) `shouldReturn` Nothing
    toJSON history `shouldSatisfy` (\case Object fields -> KeyMap.lookup "handle" fields == Just (String "m#1"); _ -> False)

  it "exposes typed admin facts with active task links, coalescing and obligations" $ do
    (turn, seedMessage, actor) <- seed pool 900 1
    now <- getCurrentTime
    Right monitor <- withDb pool (armLedgerMatchMonitor (GroupId 900) actor turn "watch" (LedgerMatchSpec Nothing (Just "match") Nothing False) 0 (addUTCTime 86400 now) 100 Map.empty)
    insertOccurrence pool monitor "active"
    claimedAt <- getCurrentTime
    [fire] <- withDb pool (claimElaboratedMonitorFires "overview" claimedAt 60 10)
    admitted <- withDb pool (admitMonitorTask "overview" fire.emfFireId Nothing Map.empty seedMessage)
    hasError admitted `shouldBe` False
    insertOccurrence pool monitor "pending"
    insertOccurrence pool monitor "coalesced"
    overview <- withDb pool WorkQuery.readWorkOverview
    length overview.tasks `shouldBe` 1
    length overview.monitors `shouldBe` 1
    overview.unresolvedRequests `shouldBe` 0
    [task] <- pure overview.tasks
    [view] <- pure overview.monitors
    task.groupId `shouldBe` 900
    task.result `shouldBe` Nothing
    view.coalesced `shouldBe` 2
    view.activeTasks `shouldBe` [WorkView.ActiveTask task.taskId TaskState.Queued]
    toJSON view `shouldSatisfy` (\case Object fields -> KeyMap.lookup "active_tasks" fields == Just (String (taskHandle task.taskId <> " queued")); _ -> False)
    edge <- withDb pool durableWorkOverview
    edge `shouldBe` toJSON overview

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

  it "allows six hours for slow-model tasks without granting extra authority" $ do
    source <- seed pool 900 1
    identifier <- admit pool source "limits"
    rows <- withDb pool $ query "SELECT max_calls,max_rounds,extract(epoch FROM deadline-created_at)::integer,grants::text FROM durable_tasks WHERE task_id=?" (Only identifier)
    rows `shouldBe` [(200 :: Int, 400 :: Int, 21600 :: Int, "{}" :: Text)]

  it "caps child admission at the parent's remaining deadline" $ do
    source@(_, message, actor) <- seed pool 900 1
    identifier <- admit pool source "parent-deadline"
    parent <- claimOne pool
    void $ withDb pool $ execute "UPDATE durable_tasks SET deadline=now()+interval '10 minutes' WHERE task_id=?" (Only identifier)
    child <- withDb pool (admitTask parent message actor "child-deadline" "work" Research (object []) Map.empty)
    rows <- withDb pool $ query "SELECT child.deadline=parent.deadline FROM durable_tasks child JOIN durable_tasks parent ON parent.task_id=child.parent_task_id WHERE child.task_id=?" (Only (identifierOf child))
    rows `shouldBe` [Only True]

  it "persists retry backoff and preserves reservations across attempts" $ do
    source <- seed pool 900 1
    identifier <- admit pool source "transient"
    first <- claimOne pool
    withDb pool (authorizeTaskStep first.atrTurnId (ExecutionWork ReserveCall)) `shouldReturn` True
    withDb pool (recordTaskFailure first.atrTurnId "HTTP 503 unavailable" Transient) `shouldReturn` True
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
    withDb pool (recordTaskFailure first.atrTurnId "stale" Transient) `shouldReturn` False

  it "does not automatically retry ambiguous effects" $ do
    source <- seed pool 900 1
    identifier <- admit pool source "ambiguous"
    execution <- claimOne pool
    _ <- withDb pool (startJournalExecution execution (JournalStart "uncertain" "sandbox_exec" 1 "hash" (object []) (toJSON ([] :: [Text])) "retry-unsafe"))
    withDb pool (recordTaskFailure execution.atrTurnId "HTTP 503" Transient) `shouldReturn` True
    withDb pool (finishAgentTurn execution TurnFailed 1 Nothing Nothing)
    status pool identifier `shouldReturn` "waiting"
    withDb pool (claimTask "no-replay") `shouldReturn` []

  it "does not retry permanent failures" $ do
    source <- seed pool 900 1
    identifier <- admit pool source "permanent"
    execution <- claimOne pool
    withDb pool (recordTaskFailure execution.atrTurnId "HTTP 403" Permanent) `shouldReturn` True
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
    withDb pool (authorizeTaskStep notification (ExecutionWork CheckOnly)) `shouldReturn` False
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
    withDb pool (recordProgressDecision notification 1 (PublishProgress "task report" "useful progress")) `shouldReturn` True
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
    withDb pool (recordTaskFailure execution.atrTurnId "HTTP 503" Transient) `shouldReturn` True
    withDb pool (finishAgentTurn execution TurnFailed 1 Nothing Nothing)
    status pool identifier `shouldReturn` "failed"
    withDb pool (claimTask "spent") `shouldReturn` []

  it "retains backoff when feedback arrives during a retry" $ do
    source@(_, _, actor) <- seed pool 900 1
    identifier <- admit pool source "retry-feedback"
    execution <- claimOne pool
    withDb pool (recordTaskFailure execution.atrTurnId "HTTP 503" Transient) `shouldReturn` True
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
insertOccurrence pool monitor key = void $ withDb pool $ do
  now <- databaseNow
  recordOccurrence monitor.mrMonitorId (OccurrenceDraft key now Nothing "" False)

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
