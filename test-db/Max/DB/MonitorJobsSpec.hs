module Max.DB.MonitorJobsSpec (Max.DB.MonitorJobsSpec.spec) where

import Control.Monad (forM, forM_, void)
import Data.Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Either (isLeft, isRight)
import Data.Foldable (for_)
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Ord (Down (..))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (addUTCTime, getCurrentTime)
import Database.PostgreSQL.Simple (Only (..))
import Effectful.PostgreSQL (execute, query)
import Helpers (truncateAll, withDb)
import JobFixture (insertOccurrence, seed)
import Max.ConversationScope (conversationScopeFor)
import Max.DB.AgentTurn (AgentTurnTerminal (..), finishAgentTurn)
import Max.DB.Connection (DbPool)
import Max.DB.Monitor
import Max.DB.Monitor.Admission
import Max.DB.Monitor.Control qualified as MonitorDB
import Max.DB.Monitor.Overview qualified as WorkQuery
import Max.DB.Transaction (withTransaction)
import Max.Effects.MonitorControl qualified as MonitorCapability
import Max.Effects.MonitorQuery qualified as MonitorQueryCapability
import Max.Jobs qualified as Jobs
import Max.Monitor.Control qualified as MonitorControl
import Max.Monitor.Policy (OverlapPolicy (..))
import Max.Monitor.Types
import Max.Monitor.View qualified as WorkView
import Max.Platform.Types
import Max.Task.Delegation (parseJobResult)
import Max.Task.State (TaskStatus (..))
import Max.Task.Types
import Max.Tasks (newTaskRegistry)
import OneBot.Types (GroupId (..))
import Test.Hspec

spec :: DbPool -> Spec
spec pool = before_ (truncateAll pool) $ describe "reminder Jobs and retained business state" $ do
  it "fences monitor mutations after the bound turn ends" $ do
    jobs <- newTaskRegistry >>= Jobs.newJobs
    (turn, _, actor) <- seed pool 900 1
    now <- getCurrentTime
    let scope = MonitorCapability.MonitorControlScope (GroupId 900) (Just turn) actor Map.empty False Nothing
        reminder = MonitorCapability.armMonitor (MonitorCapability.CannedReminder "reminder" Nothing (addUTCTime 60 now))
    Right monitor <- withDb pool (MonitorCapability.runMonitorControl jobs scope reminder)
    withDb pool (finishAgentTurn turn TurnCancelled 0 (Just "cancelled"))
    withDb pool (MonitorCapability.runMonitorControl jobs scope reminder) `shouldReturn` Left MonitorControl.ArmingCallerFenced
    withDb pool (MonitorCapability.runMonitorControl jobs scope (MonitorCapability.controlMonitor monitor.mrMonitorOrdinal MonitorControl.CancelMonitor False)) `shouldReturn` Left MonitorControl.MonitorCallerFenced
    rows <- withDb pool (query "SELECT status FROM monitors" ())
    rows `shouldBe` [Only ("armed" :: Text)]

  it "binds monitor identity, role and query scope outside tool arguments" $ do
    jobs <- newTaskRegistry >>= Jobs.newJobs
    (turn, _, actor) <- seed pool 900 1
    (_, _, otherActor) <- seed pool 901 2
    now <- getCurrentTime
    let scope = MonitorCapability.MonitorControlScope (GroupId 900) (Just turn) actor (Map.singleton "context_search" "frozen") False Nothing
        reminder = MonitorCapability.armMonitor (MonitorCapability.CannedReminder "reminder" Nothing (addUTCTime 60 now))
        elaborated = MonitorCapability.armMonitor (MonitorCapability.TimeMonitor "watch" Nothing (addUTCTime 60 now))
    withDb pool (MonitorCapability.runMonitorControl jobs (scope {MonitorCapability.principal = otherActor}) reminder) `shouldReturn` Left MonitorControl.ArmingCallerFenced
    withDb pool (MonitorCapability.runMonitorControl jobs (scope {MonitorCapability.group = GroupId 901}) reminder) `shouldReturn` Left MonitorControl.ArmingCallerFenced
    withDb pool (MonitorCapability.runMonitorControl jobs scope elaborated) `shouldReturn` Left MonitorControl.MonitorArmingForbidden
    Right monitor <- withDb pool (MonitorCapability.runMonitorControl jobs (scope {MonitorCapability.armingAllowed = True}) elaborated)
    grants <- withDb pool (query "SELECT effect_ceiling->'tool_grants' FROM monitors WHERE monitor_id=?" (Only monitor.mrMonitorId))
    grants `shouldBe` [Only (object ["context_search" .= ("frozen" :: Text)])]
    withDb pool (MonitorQueryCapability.runMonitorQuery (conversationScopeFor (GroupId 901)) (MonitorQueryCapability.readMonitorHistory monitor.mrMonitorOrdinal)) `shouldReturn` Nothing
    cancelled <- withDb pool (MonitorCapability.runMonitorControl jobs scope (MonitorCapability.controlMonitor monitor.mrMonitorOrdinal MonitorControl.CancelMonitor False))
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

  it "preserves monitor snapshots across revision changes and explicit pending retention" $ do
    (turn, _, actor) <- seed pool 900 1
    now <- getCurrentTime
    Right monitor <- withDb pool (armLedgerMatchMonitor (GroupId 900) actor turn "old goal" (LedgerMatchSpec Nothing (Just "match") Nothing False) 0 (addUTCTime 86400 now) 20 Map.empty)
    insertOccurrence pool monitor "before"
    changed <- withDb pool (withTransaction (MonitorDB.controlMonitor 900 actor.unPrincipalId False monitor.mrMonitorOrdinal.unMonitorOrdinal (MonitorControl.ConfigureMonitor 1 "new goal" Coalesce 8 MonitorControl.RetainPending Nothing) False))
    changed `shouldSatisfy` isRight
    rows <- withDb pool $ query "SELECT definition_revision,definition_snapshot->>'goal',cancelled_at IS NULL FROM monitor_fires" ()
    rows `shouldBe` [(1 :: Int, "old goal" :: Text, True)]

  it "records coalescing and bounded queue overflow without deleting occurrences" $ do
    (turn, _, actor) <- seed pool 900 1
    now <- getCurrentTime
    Right monitor <- withDb pool (armLedgerMatchMonitor (GroupId 900) actor turn "watch" (LedgerMatchSpec Nothing (Just "match") Nothing False) 0 (addUTCTime 86400 now) 20 Map.empty)
    insertOccurrence pool monitor "first"
    insertOccurrence pool monitor "coalesced"
    _ <- withDb pool (withTransaction (MonitorDB.controlMonitor 900 actor.unPrincipalId False monitor.mrMonitorOrdinal.unMonitorOrdinal (MonitorControl.ConfigureMonitor 1 "watch every" QueueOccurrences 1 MonitorControl.CancelPending Nothing) False))
    insertOccurrence pool monitor "second-revision"
    insertOccurrence pool monitor "overflow"
    rows <- withDb pool $ query "SELECT disposition FROM monitor_fires ORDER BY fire_id" ()
    rows `shouldBe` map Only (["cancelled", "coalesced", "pending", "overflow"] :: [Text])

  it "requires an administrator when a legacy monitor has no owning principal" $ do
    (turn, _, actor) <- seed pool 900 1
    now <- getCurrentTime
    Right monitor <- withDb pool (armElaboratedTimeMonitor (GroupId 900) actor turn "watch" Nothing now Map.empty)
    void $ withDb pool $ execute "UPDATE monitors SET armed_by_principal_id=NULL WHERE monitor_id=?" (Only monitor.mrMonitorId)
    denied <- withDb pool (withTransaction (MonitorDB.controlMonitor 900 actor.unPrincipalId False monitor.mrMonitorOrdinal.unMonitorOrdinal MonitorControl.CancelMonitor False))
    denied `shouldSatisfy` isLeft
    allowed <- withDb pool (withTransaction (MonitorDB.controlMonitor 900 actor.unPrincipalId True monitor.mrMonitorOrdinal.unMonitorOrdinal MonitorControl.CancelMonitor False))
    allowed `shouldSatisfy` isRight

  it "snapshots monitor profiles and change policy under the definition CAS" $ do
    (turn, _, actor) <- seed pool 900 1
    now <- getCurrentTime
    Right monitor <- withDb pool (armLedgerMatchMonitor (GroupId 900) actor turn "watch" (LedgerMatchSpec Nothing (Just "match") Nothing False) 0 (addUTCTime 86400 now) 100 Map.empty)
    changed <- withDb pool (withTransaction (MonitorDB.controlMonitor 900 actor.unPrincipalId False monitor.mrMonitorOrdinal.unMonitorOrdinal (MonitorControl.ConfigureMonitor 1 "browser watch" QueueOccurrences 160 MonitorControl.RetainPending (Just (Browser, True))) False))
    changed `shouldSatisfy` isRight
    insertOccurrence pool monitor "browser"
    stale <- withDb pool (withTransaction (MonitorDB.controlMonitor 900 actor.unPrincipalId False monitor.mrMonitorOrdinal.unMonitorOrdinal (MonitorControl.ConfigureMonitor 1 "stale" QueueOccurrences 160 MonitorControl.RetainPending (Just (Sandbox, False))) False))
    stale `shouldSatisfy` isLeft
    rows <- withDb pool $ query "SELECT definition_revision,definition_snapshot->>'profile' FROM monitor_fires" ()
    rows `shouldBe` [(2 :: Int, "browser" :: Text)]

  it "compares stable observations A-A-B-A and provides the previous baseline" $ do
    (turn, message, actor) <- seed pool 900 1
    now <- getCurrentTime
    Right monitor <- withDb pool (armLedgerMatchMonitor (GroupId 900) actor turn "watch" (LedgerMatchSpec Nothing (Just "match") Nothing False) 0 (addUTCTime 86400 now) 100 Map.empty)
    notices <- forM (zip ["first", "different wording", "changed", "returned"] [True, True, False, True]) $ \(label, active) -> do
      (fire, job) <- admitOccurrence pool monitor message label
      let observation = object ["active" .= active]
          result = JobResult label (Just (object ["summary" .= label, "observation" .= observation]))
      whenPrevious job label
      forM_ ["{}", "{\"summary\":\"ok\",\"observation\":{}}", "{\"summary\":\"ok\",\"observation\":\"healthy\"}"] $ \body -> parseJobResult job body `shouldSatisfy` isLeft
      withDb pool (recordMonitorResult fire Succeeded result)
    notices `shouldBe` [True, False, True, True]

  it "throttles failures from the last notification and keeps old pending policy" $ do
    (turn, message, actor) <- seed pool 900 1
    now <- getCurrentTime
    Right monitor <- withDb pool (armLedgerMatchMonitor (GroupId 900) actor turn "watch" (LedgerMatchSpec Nothing (Just "match") Nothing False) 0 (addUTCTime 86400 now) 100 Map.empty)
    let finish label = do
          (fire, _) <- admitOccurrence pool monitor message label
          withDb pool (recordMonitorResult fire Failed (JobResult "failure" Nothing))
    finish "first" `shouldReturn` True
    finish "suppressed" `shouldReturn` False
    void $ withDb pool (execute "UPDATE monitor_fires SET notified_at=now()-interval '2 hours' WHERE notified_at IS NOT NULL" ())
    finish "later" `shouldReturn` True
    insertOccurrence pool monitor "old pending"
    Right _ <- withDb pool (withTransaction (MonitorDB.controlMonitor 900 actor.unPrincipalId False monitor.mrMonitorOrdinal.unMonitorOrdinal (MonitorControl.ConfigureMonitor 1 "new" Coalesce 40 MonitorControl.RetainPending (Just (Research, False))) False))
    [fire] <- withDb pool (claimElaboratedMonitorFires "jobs-test" now 60 10)
    Right (MonitorTaskAdmitted _ job) <- withDb pool (withTransaction (admitMonitorTaskWithin "jobs-test" fire.emfFireId Nothing Map.empty message.unCanonicalMessageId))
    job.contract `shouldSatisfy` (/= Nothing)
    withDb pool (recordMonitorResult fire.emfFireId Failed (JobResult "failure" Nothing)) `shouldReturn` False
    finish "new first" `shouldReturn` True
    finish "new same" `shouldReturn` True

  it "advances cron after overflow without creating extra Jobs" $ do
    (turn, message, actor) <- seed pool 900 1
    -- Compare at PostgreSQL timestamp precision, independent of the host clock.
    [Only now] <- withDb pool (query "SELECT now()" ())
    Right monitor <- withDb pool (armElaboratedTimeMonitor (GroupId 900) actor turn "watch" (Just "* * * * *") now Map.empty)
    Right _ <- withDb pool (withTransaction (MonitorDB.controlMonitor 900 actor.unPrincipalId False monitor.mrMonitorOrdinal.unMonitorOrdinal (MonitorControl.ConfigureMonitor 1 "watch" QueueOccurrences 1 MonitorControl.RetainPending Nothing) False))
    insertOccurrence pool monitor "first"
    insertOccurrence pool monitor "overflow"
    fires <- withDb pool (claimElaboratedMonitorFires "jobs-test" now 60 10)
    let next = addUTCTime 60 now
    outcomes <- forM fires $ \fire -> withDb pool (withTransaction (admitMonitorTaskWithin "jobs-test" fire.emfFireId (Just next) Map.empty message.unCanonicalMessageId))
    length [() | Right MonitorTaskAdmitted {} <- outcomes] `shouldBe` 1
    length [() | Right MonitorOverflow <- outcomes] `shouldBe` 1
    withDb pool (query "SELECT next_fire_at FROM monitors" ()) `shouldReturn` [Only (Just next)]

  it "cancels future occurrences separately from admitted Jobs and exposes active handles" $ do
    jobs <- newTaskRegistry >>= Jobs.newJobs
    (turn, message, actor) <- seed pool 900 1
    now <- getCurrentTime
    Right monitor <- withDb pool (armLedgerMatchMonitor (GroupId 900) actor turn "watch" (LedgerMatchSpec Nothing (Just "match") Nothing False) 0 (addUTCTime 86400 now) 100 Map.empty)
    insertOccurrence pool monitor "first"
    [fire] <- withDb pool (claimElaboratedMonitorFires "jobs-test" now 60 10)
    Right (MonitorTaskAdmitted identifier job) <- withDb pool (withTransaction (admitMonitorTaskWithin "jobs-test" fire.emfFireId Nothing Map.empty message.unCanonicalMessageId))
    Right _ <- Jobs.admitJob jobs Nothing identifier job
    Object overview <- withDb pool (WorkQuery.readWorkOverview jobs)
    KeyMap.lookup "tasks" overview `shouldSatisfy` (\case Just (Array rows) -> length rows == 1; _ -> False)
    let scope = MonitorCapability.MonitorControlScope (GroupId 900) (Just turn) actor Map.empty False Nothing
        cancel work = withDb pool (MonitorCapability.runMonitorControl jobs scope (MonitorCapability.controlMonitor monitor.mrMonitorOrdinal MonitorControl.CancelMonitor work))
    cancel False >>= (`shouldSatisfy` isRight)
    fmap (fmap (.status)) (Jobs.lookupJob jobs (GroupId 900) identifier) `shouldReturn` Just Queued
    cancel True >>= (`shouldSatisfy` isRight)
    fmap (fmap (.status)) (Jobs.lookupJob jobs (GroupId 900) identifier) `shouldReturn` Just Cancelled

admitOccurrence :: DbPool -> MonitorRef -> CanonicalMessageId -> Text -> IO (MonitorFireId, JobSpec)
admitOccurrence pool monitor message label = do
  insertOccurrence pool monitor label
  now <- getCurrentTime
  [fire] <- withDb pool (claimElaboratedMonitorFires "jobs-test" now 60 10)
  Right (MonitorTaskAdmitted _ job) <- withDb pool (withTransaction (admitMonitorTaskWithin "jobs-test" fire.emfFireId Nothing Map.empty message.unCanonicalMessageId))
  pure (fire.emfFireId, job)

whenPrevious :: JobSpec -> Text -> Expectation
whenPrevious job label = case job.inputs of
  Object fields | label == "different wording" -> KeyMap.lookup "previous_observation" fields `shouldBe` Just (object ["active" .= True])
  _ -> pure ()
