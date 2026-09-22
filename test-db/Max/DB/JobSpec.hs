module Max.DB.JobSpec (Max.DB.JobSpec.spec) where

import Control.Concurrent.STM (atomically)
import Control.Monad (forM_, void)
import Data.Aeson (Value (Null), object, (.=))
import Data.Either (isLeft)
import Data.Int (Int64)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Database.PostgreSQL.Simple (Only (..))
import Effectful.PostgreSQL (query)
import Helpers (truncateAll, withDb, withDbLog)
import JobFixture
import Max.DB.AgentTurn
import Max.DB.Connection (DbPool)
import Max.DB.Health (operationalChecks)
import Max.DB.Job (allocateJobId)
import Max.Effects.Outbound
import Max.Effects.TaskControl qualified as Control
import Max.Effects.TaskExecution qualified as Progress
import Max.Effects.TaskQuery qualified as Query
import Max.Handler.Jobs (shutdownJobs)
import Max.IR (Body (..), Node (NText))
import Max.Jobs qualified as Jobs
import Max.MessageKind (MessageKind (KindChat))
import Max.Platform.Delivery.Queue (newDeliveryQueue, pendingDeliveryCount)
import Max.Platform.Types (CanonicalMessageId (..), DeliveryId (..))
import Max.Task.Types
import Max.Tasks (beginTurnRuntime, cancelAgentTurnTask, newTaskRegistry)
import Max.Turn.Types
import OneBot.Types (GroupId (..), UserId (..))
import Test.Hspec

spec :: DbPool -> Spec
spec pool = before_ (truncateAll pool) $ describe "Jobs database boundaries" $ do
  it "publishes a root interruption notice directly and retains it for delivery drain" $ do
    running <- runningJob pool Basic Map.empty
    deliveries <- newDeliveryQueue (DeliveryId 0)
    withDbLog pool . runOutbound running.tasks running.jobs deliveries $ shutdownJobs running.jobs
    rows <- withDb pool (query "SELECT rendered_text,reply_to_canonical_message_id FROM messages WHERE message_origin='outbound'" ())
    case rows of
      [(body, source)] -> do
        (body :: Text) `shouldSatisfy` T.isInfixOf "服务重启"
        CanonicalMessageId source `shouldBe` running.job.spec.source
      _ -> expectationFailure "expected one shutdown notice"
    atomically (pendingDeliveryCount deliveries) `shouldReturn` 1
    withDbLog pool . runOutbound running.tasks running.jobs deliveries $ shutdownJobs running.jobs
    atomically (pendingDeliveryCount deliveries) `shouldReturn` 1

  it "retains non-reusable public identities without storing execution rows" $ do
    first <- withDb pool allocateJobId
    tasks <- newTaskRegistry
    restarted <- Jobs.newJobs tasks
    Jobs.listJobs restarted (GroupId 900) `shouldReturn` []
    second <- withDb pool allocateJobId
    second `shouldSatisfy` (> first)
    withDb pool (query "SELECT count(*) FROM durable_tasks" ()) `shouldReturn` [Only (0 :: Int64)]

  it "rechecks the bound actor and conversation before task control" $ do
    running <- runningJob pool Basic Map.empty
    (_, _, other) <- seed pool 900 2
    let owner = scope running
    Right child <- withDb pool . Control.runTaskControl running.jobs owner $ Control.startTask "child" Basic Null
    let steer bound = withDb pool . Control.runTaskControl running.jobs bound $ Control.controlTask child.run.jobId (SteerJob "feedback")
    steer (owner {Control.principal = other}) >>= (`shouldSatisfy` isLeft)
    steer (owner {Control.group = GroupId 901}) >>= (`shouldSatisfy` isLeft)
    steer owner `shouldReturn` Right ()
    withDb pool (finishAgentTurn running.turn TurnSucceeded 0 Nothing)
    steer owner >>= (`shouldSatisfy` isLeft)

  it "takes child authority from the bound scope and requires the authenticated source" $ do
    running <- runningJob pool Sandbox (Map.fromList [("task_start", "v1"), ("sandbox_exec", "v1")])
    let caller = scope running
        start bound = withDb pool . Control.runTaskControl running.jobs bound $ Control.startTask "child" Basic (object ["grants" .= object ["sandbox_exec" .= ("forged" :: Text)]])
    Right child <- start caller
    child.spec.grants `shouldBe` Map.singleton "task_start" "v1"
    child.spec.parent `shouldBe` Just running.job.run
    (_, otherSource, _) <- seed pool 901 2
    start (caller {Control.source = otherSource}) >>= (`shouldSatisfy` isLeft)
    withDb pool (query "SELECT count(*) FROM durable_tasks" ()) `shouldReturn` [Only (0 :: Int64)]

  it "binds query and progress capabilities without exposing another conversation" $ do
    running <- runningJob pool Basic Map.empty
    withDb pool (Query.runTaskQuery running.jobs (GroupId 901) Query.listTasks) `shouldReturn` []
    withDb pool (Query.runTaskQuery running.jobs (GroupId 901) (Query.readTask running.job.run.jobId)) `shouldReturn` Nothing
    withDb pool (Progress.runTaskExecution running.jobs Nothing (Progress.reportProgress "no caller")) >>= (`shouldSatisfy` isLeft)
    withDb pool (Progress.runTaskExecution running.jobs (Just running.turn.atrTurnId) (Progress.reportProgress "latest progress")) `shouldReturn` Right ()
    void (cancelAgentTurnTask running.tasks running.turn.atrTurnId)
    withDb pool (Control.runTaskControl running.jobs (scope running) (Control.startTask "late" Basic Null)) >>= (`shouldSatisfy` isLeft)

  it "blocks background output and revokes a stale progress notice at the shared publisher" $ do
    running <- runningJob pool Basic Map.empty
    deliveries <- newDeliveryQueue (DeliveryId 0)
    let request turn = OutboundRequest KindChat (GroupId 900) (Body [NText "output"]) Nothing DeliverConversation (Just (TurnOutputLink turn.atrTurnId 0)) Nothing
        publish turn = withDbLog pool . runOutbound running.tasks running.jobs deliveries $ sendRecorded (request turn)
    publish running.turn >>= (`shouldSatisfy` publicationFailed)
    Jobs.reportJobProgress running.jobs running.turn.atrTurnId "progress" `shouldReturn` True
    Jobs.PublishJobNotice job version _ <- Jobs.takeJobWork running.jobs
    (notice, _, _) <- seed pool 900 1
    -- A missing runtime is denied even if a caller guesses a valid job notice.
    Jobs.bindJobNotice running.jobs notice.atrTurnId job.run version
    publish notice >>= (`shouldSatisfy` publicationFailed)
    _ <- beginTurnRuntime running.tasks notice (GroupId 900) (UserId 1) Nothing
    publish notice >>= (`shouldSatisfy` (not . publicationFailed))
    Jobs.reportJobProgress running.jobs running.turn.atrTurnId "newer progress" `shouldReturn` True
    publish notice >>= (`shouldSatisfy` publicationFailed)
    withDb pool (query "SELECT count(*) FROM messages WHERE agent_turn_id IS NOT NULL" ()) `shouldReturn` [Only (1 :: Int64)]

  it "terminalizes interrupted turns at boot without creating another job" $ do
    running <- runningJob pool Basic Map.empty
    _ <- withDb pool reclaimInterruptedTurns
    rows <- withDb pool (query "SELECT status FROM agent_turns WHERE turn_id=?" (Only running.turn.atrTurnId))
    rows `shouldBe` [Only ("crashed" :: Text)]
    fresh <- Jobs.newJobs running.tasks
    Jobs.listJobs fresh (GroupId 900) `shouldReturn` []

  it "runs all current operational queries against the upgraded schema" $ do
    forM_ operationalChecks $ \(_, _, sql) -> do
      rows <- withDb pool (query sql ())
      length (rows :: [Only Int64]) `shouldBe` 1

scope :: RunningJob -> Control.TaskControlScope
scope running = Control.TaskControlScope running.job.spec.group (Just running.turn) running.job.spec.source running.job.spec.principal running.job.spec.grants

publicationFailed :: PublicationResult -> Bool
publicationFailed PublicationFailed {} = True
publicationFailed _ = False
