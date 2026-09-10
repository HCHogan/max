module Max.TaskExperienceSpec (spec) where

import Control.Monad (void)
import Data.Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.Int (Int64)
import Data.Maybe (isJust)
import Data.Text (Text)
import Database.PostgreSQL.Simple.Types (Only (..))
import Effectful.PostgreSQL (execute, query)
import Helpers (truncateAll, withDb, withDbLog)
import Max.ConversationScope (conversationScopeFor)
import Max.DB.AgentTurn
import Max.DB.Connection (DbPool)
import Max.DB.Task (taskReportTyped)
import Max.DB.Task.Experience
import Max.DB.TaskSpec (admit, claimOne, seed)
import Max.Task.Experience
import Max.Task.State (ReportStatus (ReportSucceeded), TaskReport (..))
import Max.Turn.Types
import OneBot.Types (GroupId (..))
import Test.Hspec

spec :: DbPool -> Spec
spec pool = before_ (truncateAll pool) $ describe "task experience lifecycle" $ do
  let scope = conversationScopeFor (GroupId 900)
      outside = conversationScopeFor (GroupId 901)
  it "requires actual successful journal evidence and scopes candidates to the original conversation" $ do
    source <- seed pool 900 1
    task <- admit pool source "candidate"
    void $ withDb pool (execute "UPDATE durable_tasks SET status='cancelled' WHERE task_id=?" (Only task))
    withDb pool (taskExperienceSnapshot scope task) `shouldReturn` Nothing
    (ready, handle) <- complete pool 900 "complete"
    withDb pool (createExperienceCandidate outside ready (capsule handle)) `shouldReturn` Left "task is not verifiably complete in scope, or cited receipt is unavailable"
    withDb pool (createExperienceCandidate scope ready (capsule "t#999:r1")) `shouldReturn` Left "task is not verifiably complete in scope, or cited receipt is unavailable"
    Right _ <- withDb pool (createExperienceCandidate scope ready (capsule handle))
    [Only count] <- withDb pool (query "SELECT count(*) FROM skills" ())
    (count :: Int64) `shouldBe` 0
  it "publishes only after a current paired replay, cannot override builtins, and supports invalidation" $ do
    (source, handle) <- complete pool 900 "source"
    Right candidateId <- withDb pool (createExperienceCandidate scope source (capsule handle))
    withDb pool (publishExperience scope candidateId 1) `shouldReturn` False
    (later, _) <- complete pool 900 "later"
    packet <- withDb pool (exportExperienceReplay scope candidateId later)
    packet `shouldSatisfy` isJust
    let paired = reportFor packet
    withDb pool (reviewExperienceReplay outside candidateId later "operator" paired) `shouldReturn` Nothing
    Just proof <- withDb pool (reviewExperienceReplay scope candidateId later "operator" paired)
    withDb pool (publishExperience scope candidateId proof) `shouldReturn` True
    [Only name] <- withDb pool (query "SELECT name FROM skills" ())
    (name :: Text) `shouldBe` "learned-task-1"
    [Only group] <- withDb pool (query "SELECT group_id FROM skills" ())
    (group :: Int64) `shouldBe` 900
    withDb pool (publishExperience scope candidateId proof) `shouldReturn` False
    withDb pool (invalidateExperience scope candidateId "source API changed") `shouldReturn` True
    [Only enabled] <- withDb pool (query "SELECT enabled FROM skills" ())
    enabled `shouldBe` False
  it "rejects stale task fingerprints and a later failed replay" $ do
    (source, handle) <- complete pool 900 "source"
    Right candidateId <- withDb pool (createExperienceCandidate scope source (capsule handle))
    (later, _) <- complete pool 900 "later"
    packet <- withDb pool (exportExperienceReplay scope candidateId later)
    let paired = reportFor packet
    Just proof <- withDb pool (reviewExperienceReplay scope candidateId later "operator" paired)
    Just _ <- withDb pool (reviewExperienceReplay scope candidateId later "operator" paired {cases = []})
    withDb pool (publishExperience scope candidateId proof) `shouldReturn` False
    void $ withDb pool (execute "UPDATE durable_tasks SET objective='changed' WHERE task_id=?" (Only later))
    withDb pool (reviewExperienceReplay scope candidateId later "operator" paired) `shouldReturn` Nothing

complete :: DbPool -> Int64 -> Text -> IO (Int64, Text)
complete pool group key = do
  front <- seed pool group 1
  task <- admit pool front key
  execution <- claimOne pool
  receipt <- withDb pool (startJournalExecution execution (JournalStart "proof" "get_state" 1 "schema" (object []) (toJSON (["read"] :: [Text])) "safe"))
  withDbLog pool (finishJournalExecution receipt (JournalSucceeded (object ["verified" .= True])))
  let handle = resultHandleText execution.atrTurnOrdinal receipt.jeExecutionOrdinal
  withDb pool (taskReportTyped execution.atrTurnId (TaskReport ReportSucceeded "verified" [handle] [] Nothing Nothing)) `shouldReturn` True
  withDb pool (finishAgentTurn execution TurnSucceeded 1 Nothing Nothing)
  pure (task, handle)

capsule :: Text -> ExperienceCapsule
capsule handle = ExperienceCapsule "确认修复后的状态" "状态修复任务" "读取当前值，修复后再次读取确认" "接口语义或目标改变" [handle]

reportFor :: Maybe Value -> ReplayReport
reportFor (Just (Object fields)) =
  ReplayReport
    (get "capsule_fingerprint")
    (get "later_fingerprint")
    [ReplayCase prompt ["verified"] ["deploy"] "missing" "verified" 100 110 100 100 Nothing Nothing | prompt <- ["version", "scope", "evidence"]]
    "fixture"
  where
    get key = case KM.lookup key fields of Just (String text) -> text; _ -> error "missing fingerprint"
reportFor _ = error "no export packet"
