module Max.DB.ReminderSpec (spec) where

import Control.Monad (void)
import Data.Int (Int64)
import Data.Maybe (isJust)
import Data.Time (UTCTime, addUTCTime, diffUTCTime, getCurrentTime)
import Database.PostgreSQL.Simple (Only (..))
import Effectful.PostgreSQL (query)
import Helpers (insertRawMessage, testTime, truncateAll, withDb)
import Max.DB.Connection (DbPool)
import Max.DB.Reminder
  ( Reminder (..),
    cancelReminder,
    dueReminders,
    insertReminder,
    listPending,
    nextPending,
    recordDeliveryFailure,
    reminderDueAt,
    rescheduleReminder,
  )
import Max.Platform.Types (PrincipalId (..))
import OneBot.Types (GroupId (..), UserId (..))
import Test.Hspec

spec :: DbPool -> Spec
spec pool = do
  -- reminders.author_principal_id references principals since ADR 004, so the
  -- asker has to be a person the ledger knows.  Principals survive
  -- truncateAll, so one seed up front is reused by every example.
  asker <- runIO (seedAsker pool)
  before_ (void (seedAsker pool)) $ describe "Max.DB.Reminder delivery state" $ do
    it "persists a retry deadline so a restarted worker does not lose or hot-loop the reminder" $ do
      now <- getCurrentTime
      let originalFire = addUTCTime (-10) now
          retryAt = addUTCTime 30 now
      rid <-
        withDb pool $
          insertReminder
            (GroupId 42)
            (PrincipalId asker)
            (UserId 99)
            "喝水"
            Nothing
            originalFire

      dueBefore <- withDb pool (dueReminders now)
      map (.rmId) dueBefore `shouldBe` [rid]
      withDb pool (recordDeliveryFailure rid "connection closed" (Just retryAt))

      -- These fresh queries are exactly what a new process performs on boot.
      dueDuringBackoff <- withDb pool (dueReminders now)
      restarted <- withDb pool nextPending
      dueDuringBackoff `shouldBe` []
      case restarted of
        Nothing -> expectationFailure "retry disappeared across the DB boundary"
        Just r -> do
          r.rmId `shouldBe` rid
          r.rmDeliveryAttempts `shouldBe` 1
          r.rmLastError `shouldBe` Just "connection closed"
          r.rmFireAt `shouldBeWithinMicros` originalFire
          reminderDueAt r `shouldBeWithinMicros` retryAt

      dueAtRetry <- withDb pool (dueReminders (addUTCTime 0.000001 retryAt))
      map (.rmId) dueAtRetry `shouldBe` [rid]

    it "parks an exhausted reminder but keeps it visible and cancellable" $ do
      now <- getCurrentTime
      rid <-
        withDb pool $
          insertReminder
            (GroupId 42)
            (PrincipalId asker)
            (UserId 99)
            "喝水"
            Nothing
            now
      mapM_
        (\n -> withDb pool (recordDeliveryFailure rid ("failure " <> n) (Just now)))
        ["1", "2", "3", "4"]
      withDb pool (recordDeliveryFailure rid "failure 5" Nothing)

      withDb pool nextPending `shouldReturn` Nothing
      [parked] <- withDb pool (listPending (GroupId 42))
      parked.rmDeliveryAttempts `shouldBe` 5
      parked.rmParkedAt `shouldSatisfy` isJust
      withDb pool (cancelReminder (GroupId 42) rid) `shouldReturn` True

    it "clears retry metadata when a recurring delivery is acknowledged" $ do
      now <- getCurrentTime
      let nextFire = addUTCTime 3600 now
      rid <-
        withDb pool $
          insertReminder
            (GroupId 42)
            (PrincipalId asker)
            (UserId 99)
            "喝水"
            (Just "0 * * * *")
            now
      withDb pool (recordDeliveryFailure rid "temporary" (Just (addUTCTime 30 now)))
      withDb pool (rescheduleReminder rid nextFire)
      [acknowledged] <- withDb pool (listPending (GroupId 42))
      acknowledged.rmDeliveryAttempts `shouldBe` 0
      acknowledged.rmNextAttemptAt `shouldBe` Nothing
      acknowledged.rmLastError `shouldBe` Nothing
      acknowledged.rmParkedAt `shouldBe` Nothing
      acknowledged.rmFireAt `shouldBeWithinMicros` nextFire

shouldBeWithinMicros :: UTCTime -> UTCTime -> Expectation
shouldBeWithinMicros actual expected =
  abs (diffUTCTime actual expected) `shouldSatisfy` (< 0.000001)

-- | The QQ number the fixture reminders are asked from, resolved to the
-- principal the column now names.
seedAsker :: DbPool -> IO Int64
seedAsker pool = do
  truncateAll pool
  _ <- insertRawMessage pool 5001 42 7 99 testTime Nothing "set me a reminder"
  rows <-
    withDb pool $
      query "SELECT principal_id FROM principal_identities WHERE native_user_id = '7'" ()
  case rows :: [Only Int64] of
    Only principal : _ -> pure principal
    [] -> expectationFailure "seeded asker has no principal" >> pure 0
