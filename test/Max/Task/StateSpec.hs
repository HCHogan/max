module Max.Task.StateSpec (spec) where

import Data.Aeson (object, (.=))
import Data.Text (Text)
import Data.Time (UTCTime (..), addUTCTime, fromGregorian)
import Max.Task.State
import Test.Hspec

spec :: Spec
spec = describe "typed task settlement" $ do
  it "retries a transient failure with bounded exponential backoff" $ do
    let next = decideSettlement facts
    next.status `shouldBe` Retrying
    next.retryAt `shouldBe` Just (addUTCTime 5 testNow)
    map retryDelaySeconds [0, 1, 2, 5, 6, 100] `shouldBe` [5, 10, 20, 160, 300, 300]
  it "retains evidence and unresolved work while waiting for ambiguous effects" $ do
    let report = failed {unresolved = ["check the receipt"]}
        next = decideSettlement facts {report = Just report, ambiguousEffects = True}
    next.status `shouldBe` Waiting
    next.retryAt `shouldBe` Nothing
    next.report.unresolved `shouldContain` ["check the receipt"]
    next.report.evidence `shouldBe` ["journal#1"]
  it "does not retry after deadline, budget or attempt exhaustion" $ do
    map
      (\input -> (decideSettlement input).status)
      [facts {deadline = testNow}, facts {budgetExhausted = True}, facts {attempt = 40}]
      `shouldBe` [Failed, Failed, Failed]
  it "gives an unreported exhausted execution a host budget outcome" $ do
    let next = decideSettlement facts {report = Nothing, budgetExhausted = True}
    next.status `shouldBe` BudgetExhausted
    next.report.status `shouldBe` ReportBudgetExhausted
  it "queues new durable input after a successful attempt instead of notifying a stale result" $ do
    let next = decideSettlement facts {report = Just (TaskReport ReportSucceeded "done" [] [] Nothing Nothing), pendingInput = True}
    next.status `shouldBe` Queued
    next.retryAt `shouldBe` Nothing
  it "rejects model-authored host control statuses" $ do
    parseTaskReport (object ["status" .= ("cancelled" :: Text), "summary" .= ("stop" :: Text)]) `shouldSatisfy` either (const True) (const False)
  it "rejects oversized and blank model reports at the boundary" $ do
    parseTaskReport (object ["status" .= ("succeeded" :: Text), "summary" .= ("  " :: Text)]) `shouldSatisfy` either (const True) (const False)

  it "allows attributed steering without transferring owner control" $ do
    let peer = TaskControlFacts Running 3 False True False
    decideTaskControl Steer Nothing "suggestion" peer `shouldBe` Right ApplyControl
    decideTaskControl Cancel Nothing "stop" peer `shouldBe` Left TaskOwnerRequired
    decideTaskControl Replace (Just 3) "different objective" peer `shouldBe` Left TaskOwnerRequired
  it "requires fresh provenance even for a repeated control event" $ do
    decideTaskControl Cancel Nothing "stop" (TaskControlFacts Running 3 True False True)
      `shouldBe` Left InvalidEventProvenance
  it "acknowledges a repeated authorized event without reapplying its old revision" $ do
    decideTaskControl Replace (Just 2) "updated goal" (TaskControlFacts Running 3 True True True)
      `shouldBe` Right ReplayControl
  it "requires owner authority to resume waiting work and rejects closed work" $ do
    decideTaskControl Steer Nothing "continue" (TaskControlFacts Waiting 3 False True False)
      `shouldBe` Left TaskResumeOwnerRequired
    decideTaskControl Steer Nothing "continue" (TaskControlFacts Cancelled 3 True True False)
      `shouldBe` Left TaskClosed

testNow :: UTCTime
testNow = UTCTime (fromGregorian 2026 9 6) 0

failed :: TaskReport
failed = TaskReport ReportFailed "temporarily unavailable" ["journal#1"] [] (Just Transient) Nothing

facts :: SettlementFacts
facts = SettlementFacts testNow (addUTCTime 600 testNow) 1 0 False False False False (Just failed) Nothing
