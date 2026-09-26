module Max.DB.ProgressSpec (Max.DB.ProgressSpec.spec) where

import Control.Monad (forM_)
import Data.Int (Int64)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Text qualified as T
import Database.PostgreSQL.Simple (Only (..))
import Database.PostgreSQL.Simple.FromRow (field)
import Effectful.PostgreSQL (query)
import Helpers (truncateAll, withDb, withDbLog)
import JobFixture
import Max.DB.Codec (jsonField, queryRows)
import Max.DB.Connection (DbPool)
import Max.Effects.Outbound (runOutbound)
import Max.IR (Body (..), Node (NMention, NText), Phase (Canonical))
import Max.Jobs qualified as Jobs
import Max.Node.Router qualified as Router
import Max.Platform.Delivery.Queue (newDeliveryQueue)
import Max.Platform.Types (DeliveryId (..))
import Max.ReplySend
import Max.Task.State (TaskStatus (Succeeded))
import Max.Task.Types (JobResult (..), JobRun (jobId), JobSpec (principal), JobView (..), TaskProfile (Basic))
import Max.Tasks (beginTurnRuntime)
import Max.Turn.Types
import NodeWorkFixture qualified
import OneBot.Types (GroupId (..), UserId (..))
import Test.Hspec

spec :: DbPool -> Spec
spec pool = before_ (truncateAll pool) $ describe "job notice publication" $ do
  forM_ [False, True] $ \messageRelay ->
    it (if messageRelay then "fences urgent-message relay publication through the shared resolver" else "fences report relay publication through the shared resolver") $ do
      running <- runningJob pool Basic Map.empty
      (front, _, _) <- seed pool 900 1
      if messageRelay
        then do
          Jobs.tellParent running.jobs running.turn.atrTurnId "urgent evidence" True `shouldReturn` Right ()
          Right (Router.ChildMessage relay) <- NodeWorkFixture.takeWork running.jobs
          Jobs.bindMessageRelay running.jobs front.atrTurnId relay
        else do
          Jobs.completeJob running.jobs running.job.run Succeeded (JobResult "result" Nothing)
          Right (Router.JobReport relay) <- NodeWorkFixture.takeWork running.jobs
          Jobs.bindReportRelay running.jobs front.atrTurnId relay
      [Only principal] <- withDb pool $ query "SELECT author_principal_id FROM messages ORDER BY canonical_message_id LIMIT 1" ()
      [Only source] <- withDb pool $ query "SELECT canonical_message_id FROM messages ORDER BY canonical_message_id LIMIT 1" ()
      output <- newTurnOutputContext front
      let text = "[reply#" <> T.pack (show (source :: Int64)) <> "] [mention#" <> T.pack (show (principal :: Int64)) <> ": Alice] 新证据\n\n正在验证"
          target = ReplyTarget (GroupId 900) [] Nothing False True True False False (Just output)
      deliveries <- newDeliveryQueue (DeliveryId 0)
      let registry = running.tasks
      _ <- beginTurnRuntime registry front (GroupId 900) (UserId 1) Nothing
      published <- withDbLog pool $ runOutbound registry running.jobs deliveries $ sendAndPersistReply target emptySendState text
      length published.committed `shouldBe` 2
      published.failure `shouldBe` Nothing
      rows <- withDb pool $ queryRows ((,) <$> jsonField <*> field) "SELECT canonical_content::text,reply_to_canonical_message_id FROM messages WHERE agent_turn_id=? ORDER BY canonical_message_id" (Only front.atrTurnId)
      case rows of
        [(body :: Body 'Canonical, reply :: Maybe Int64), (tailBody, tailReply)] -> do
          length [() | NMention {} <- body.nodes] `shouldBe` 1
          reply `shouldBe` Just source
          [value | NText value <- body.nodes] `shouldSatisfy` (not . any (T.isInfixOf "mention#"))
          tailReply `shouldBe` Nothing
          T.strip (T.concat [value | NText value <- tailBody.nodes]) `shouldBe` "正在验证"
        _ -> expectationFailure "missing canonical publication"

      -- Replacement fences the same already-started relay at the actual shared
      -- publication boundary, including its fallback path.
      Jobs.replaceJob running.jobs (GroupId 900) running.job.spec.principal False running.job.run.jobId "replacement" `shouldReturn` Right ()
      rejected <- withDbLog pool $ runOutbound registry running.jobs deliveries $ sendAndPersistReply target emptySendState "obsolete report"
      rejected.committed `shouldBe` []
      rejected.failure `shouldSatisfy` isJust
      withDb pool (query "SELECT count(*) FROM messages WHERE agent_turn_id=?" (Only front.atrTurnId)) `shouldReturn` [Only (2 :: Int)]
