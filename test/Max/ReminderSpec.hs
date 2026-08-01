module Max.ReminderSpec (spec) where

import Data.Time (UTCTime (..), addUTCTime, fromGregorian, secondsToDiffTime)
import Max.DB.Reminder (Reminder (..), reminderDueAt)
import Max.Reminder
  ( ReminderRetry (..),
    maxReminderAttempts,
    reminderRetryDecision,
  )
import Test.Hspec

at :: Integer -> UTCTime
at s = UTCTime (fromGregorian 2026 8 1) (secondsToDiffTime s)

spec :: Spec
spec = describe "reminder delivery retries" $ do
  it "uses bounded backoff and parks the fifth failed delivery" $ do
    reminderRetryDecision (at 0) 1 `shouldBe` RetryReminderAt (at 30)
    reminderRetryDecision (at 0) 2 `shouldBe` RetryReminderAt (at 120)
    reminderRetryDecision (at 0) 3 `shouldBe` RetryReminderAt (at 600)
    reminderRetryDecision (at 0) 4 `shouldBe` RetryReminderAt (at 1800)
    reminderRetryDecision (at 0) maxReminderAttempts `shouldBe` ParkReminder

  it "schedules from the durable retry deadline without rewriting fire_at" $ do
    let fireAt = at 100
        retryAt = addUTCTime 30 fireAt
        reminder = fixture {rmFireAt = fireAt, rmNextAttemptAt = Just retryAt}
    reminderDueAt reminder `shouldBe` retryAt
    reminder.rmFireAt `shouldBe` fireAt

fixture :: Reminder
fixture =
  Reminder
    { rmId = 1,
      rmGroupId = 42,
      rmUserId = 7,
      rmSelfId = 99,
      rmText = "喝水",
      rmCron = Nothing,
      rmFireAt = at 100,
      rmCreatedAt = at 0,
      rmDeliveryAttempts = 0,
      rmNextAttemptAt = Nothing,
      rmLastError = Nothing,
      rmParkedAt = Nothing
    }
