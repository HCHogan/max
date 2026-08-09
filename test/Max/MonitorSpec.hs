module Max.MonitorSpec (spec) where

import Data.Time (UTCTime (..), addUTCTime, fromGregorian, secondsToDiffTime)
import Max.DB.Monitor (TimeMonitor (..), monitorDueAt)
import Max.Monitor
  ( CannedRetry (..),
    cannedRetryDecision,
    maxCannedAttempts,
  )
import Max.Monitor.Types
  ( MonitorId (..),
    MonitorOrdinal (..),
    MonitorRef (..),
    monitorHandleText,
    parseMonitorHandle,
  )
import Test.Hspec

at :: Integer -> UTCTime
at seconds = UTCTime (fromGregorian 2026 8 1) (secondsToDiffTime seconds)

spec :: Spec
spec = do
  describe "canned monitor delivery retries" $ do
    it "uses bounded backoff and parks the fifth failed delivery" $ do
      cannedRetryDecision (at 0) 1 `shouldBe` RetryCannedAt (at 30)
      cannedRetryDecision (at 0) 2 `shouldBe` RetryCannedAt (at 120)
      cannedRetryDecision (at 0) 3 `shouldBe` RetryCannedAt (at 600)
      cannedRetryDecision (at 0) 4 `shouldBe` RetryCannedAt (at 1800)
      cannedRetryDecision (at 0) maxCannedAttempts `shouldBe` ParkCanned

    it "presents retry time without rewriting the admitted schedule" $ do
      let fireAt = at 100
          retryAt = addUTCTime 30 fireAt
          monitor = fixture {tmNextFireAt = fireAt, tmNextAttemptAt = Just retryAt}
      monitorDueAt monitor `shouldBe` retryAt
      monitor.tmNextFireAt `shouldBe` fireAt

  describe "monitor handles" $ do
    it "round-trips the scoped m# grammar" $ do
      monitorHandleText (MonitorOrdinal 12) `shouldBe` "m#12"
      parseMonitorHandle " m#12 " `shouldBe` Just (MonitorOrdinal 12)

    it "rejects bare ids and non-positive ordinals" $ do
      parseMonitorHandle "12" `shouldBe` Nothing
      parseMonitorHandle "m#0" `shouldBe` Nothing
      parseMonitorHandle "m#-1" `shouldBe` Nothing

fixture :: TimeMonitor
fixture =
  TimeMonitor
    { tmRef = MonitorRef (MonitorId 91) (MonitorOrdinal 3),
      tmGroupId = 42,
      tmAuthorPrincipalId = Just 7,
      tmArmingTurn = Nothing,
      tmText = "喝水",
      tmCron = Nothing,
      tmNextFireAt = at 100,
      tmCreatedAt = at 0,
      tmFireCount = 0,
      tmDeliveryAttempts = 0,
      tmNextAttemptAt = Nothing,
      tmLastError = Nothing,
      tmParkedAt = Nothing
    }
