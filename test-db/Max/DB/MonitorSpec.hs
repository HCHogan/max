module Max.DB.MonitorSpec (spec) where

import Control.Concurrent.Async (concurrently)
import Data.Int (Int64)
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime, addUTCTime, diffUTCTime, getCurrentTime)
import Database.PostgreSQL.Simple (Only (..))
import Effectful.PostgreSQL (query)
import Helpers (insertRawMessage, testTime, truncateAll, withDb)
import Max.ConversationScope (conversationScopeFor)
import Max.DB.Connection (DbPool)
import Max.DB.Monitor
  ( CannedMonitorFire (..),
    TimeMonitor (..),
    admitDueTimeMonitors,
    armCannedTimeMonitor,
    cancelMonitor,
    claimCannedMonitorFires,
    completeCannedMonitorFire,
    listCannedTimeMonitors,
    lookupMonitorFireOutput,
    reclaimExpiredMonitorFireClaims,
    recordMonitorFireFailure,
  )
import Max.IR (Body (..), Node (NText))
import Max.Monitor.Types (MonitorFireId, MonitorOrdinal (..), MonitorRef (..))
import Max.Platform.Store (EnqueuedOutbound (..), OutboundDraft (..), enqueueOutbound)
import Max.Platform.Types (CanonicalMessageId (..), PrincipalId (..))
import OneBot.Types (GroupId (..))
import Test.Hspec

spec :: DbPool -> Spec
spec pool = describe "Max.DB.Monitor TimeCron + canned" $ do
  it "allocates durable conversation-scoped m# ordinals and resolves cancellation in scope" $ do
    truncateAll pool
    asker <- seedConversation pool 5001 42 7
    now <- getCurrentTime
    (left, right) <-
      concurrently
        (withDb pool (arm asker 42 "left" (addUTCTime 60 now)))
        (withDb pool (arm asker 42 "right" (addUTCTime 120 now)))
    map (.mrMonitorOrdinal) [left, right]
      `shouldMatchList` [MonitorOrdinal 1, MonitorOrdinal 2]

    otherAsker <- seedConversation pool 5002 43 8
    other <- withDb pool (arm otherAsker 43 "other" (addUTCTime 180 now))
    other.mrMonitorOrdinal `shouldBe` MonitorOrdinal 1
    withDb pool (cancelMonitor (conversationScopeFor (GroupId 43)) (MonitorOrdinal 2))
      `shouldReturn` False
    withDb pool (cancelMonitor (conversationScopeFor (GroupId 42)) (MonitorOrdinal 2))
      `shouldReturn` True

    -- Admission and cancellation serialize on the monitor row. Whichever
    -- wins, cancellation cannot leave a live fire behind.
    racedAsker <- seedConversation pool 5003 44 9
    raced <- withDb pool (arm racedAsker 44 "raced" (addUTCTime (-1) now))
    (_, cancelled) <-
      concurrently
        (withDb pool (admitDueTimeMonitors now))
        (withDb pool (cancelMonitor (conversationScopeFor (GroupId 44)) raced.mrMonitorOrdinal))
    cancelled `shouldBe` True
    active <-
      withDb pool $
        query
          "SELECT count(*) FROM monitor_fires WHERE monitor_id=? \
          \ AND admission_state='pending' AND cancelled_at IS NULL"
          (Only raced.mrMonitorId)
    (active :: [Only Int64]) `shouldBe` [Only 0]

  it "survives every pre-ack crash boundary without publishing a duplicate" $ do
    truncateAll pool
    asker <- seedConversation pool 5101 42 7
    observedAt <- getCurrentTime
    monitor <- withDb pool (arm asker 42 "喝水" (addUTCTime (-1) observedAt))

    -- observation -> pending: repeated evaluation admits one occurrence.
    withDb pool (admitDueTimeMonitors observedAt) `shouldReturn` 1
    withDb pool (admitDueTimeMonitors observedAt) `shouldReturn` 0
    claimAt <- getCurrentTime
    [claimed] <-
      withDb pool $
        claimCannedMonitorFires "scheduler-a" claimAt (addUTCTime 60 claimAt) 10
    claimed.cmfMonitor `shouldBe` monitor
    withDb pool (lookupMonitorFireOutput claimed.cmfFireId) `shouldReturn` Nothing

    -- claim -> canonical dispatch: publication commits fire provenance and a
    -- durable platform-delivery intent in the same transaction.
    queued <-
      withDb pool $
        enqueueOutbound
          OutboundDraft
            { legacyConversationId = 42,
              transcriptKind = "chat",
              sourceCanonicalMessageId = Nothing,
              canonicalBody = Body [NText "⏰ 提醒：喝水"],
              replyToCanonicalMessageId = Nothing,
              turnOutputLink = Nothing,
              monitorFireId = Just claimed.cmfFireId
            }
    withDb pool (lookupMonitorFireOutput claimed.cmfFireId)
      `shouldReturn` Just queued.canonicalMessageId
    deliveryCount <-
      withDb pool $
        query
          "SELECT count(*) FROM message_deliveries WHERE canonical_message_id=? AND status='pending'"
          (Only queued.canonicalMessageId.unCanonicalMessageId)
    (deliveryCount :: [Only Int64]) `shouldBe` [Only 1]

    -- Simulate process death before fire ack. A live lease blocks takeover;
    -- boot after expiry releases it and a new owner rediscovers the same row.
    withDb pool (claimCannedMonitorFires "scheduler-b" claimAt (addUTCTime 60 claimAt) 10)
      `shouldReturn` []
    let restartedAt = addUTCTime 61 claimAt
    withDb pool (reclaimExpiredMonitorFireClaims restartedAt) `shouldReturn` 1
    [resumed] <-
      withDb pool $
        claimCannedMonitorFires "scheduler-b" restartedAt (addUTCTime 60 restartedAt) 10
    resumed.cmfFireId `shouldBe` claimed.cmfFireId
    withDb
      pool
      ( completeCannedMonitorFire
          "scheduler-b"
          resumed.cmfFireId
          (Just queued.canonicalMessageId)
          Nothing
      )
      `shouldReturn` True

    published <-
      withDb pool $
        query "SELECT count(*) FROM messages WHERE monitor_fire_id=?" (Only resumed.cmfFireId)
    (published :: [Only Int64]) `shouldBe` [Only 1]
    state <-
      withDb pool $
        query
          "SELECT f.admission_state, m.status, m.fire_count \
          \ FROM monitor_fires f JOIN monitors m USING (monitor_id) WHERE f.fire_id=?"
          (Only resumed.cmfFireId)
    (state :: [(Text, Text, Int64)]) `shouldBe` [("dispatched", "fired", 1)]
    withDb pool (listCannedTimeMonitors (conversationScopeFor (GroupId 42)))
      `shouldReturn` []

  it "persists bounded retry/backoff and leaves an exhausted fire visible and cancellable" $ do
    truncateAll pool
    asker <- seedConversation pool 5201 42 7
    observedAt <- getCurrentTime
    monitor <- withDb pool (arm asker 42 "喝水" (addUTCTime (-1) observedAt))
    _ <- withDb pool (admitDueTimeMonitors observedAt)
    claimAt <- getCurrentTime
    [first] <- withDb pool (claimAtTime "retry-worker" claimAt)
    parkThroughFive pool "retry-worker" first.cmfFireId claimAt 1

    claims <- withDb pool (claimAtTime "another-worker" (addUTCTime 3600 claimAt))
    claims `shouldBe` []
    [parked] <- withDb pool (listCannedTimeMonitors (conversationScopeFor (GroupId 42)))
    parked.tmRef `shouldBe` monitor
    parked.tmDeliveryAttempts `shouldBe` 5
    parked.tmParkedAt `shouldSatisfy` isJust
    parked.tmLastError `shouldBe` Just "failure 5"
    withDb pool (cancelMonitor (conversationScopeFor (GroupId 42)) monitor.mrMonitorOrdinal)
      `shouldReturn` True

  it "reconciles a published but unacknowledged occurrence when cancel wins" $ do
    truncateAll pool
    asker <- seedConversation pool 5251 42 7
    observedAt <- getCurrentTime
    monitor <- withDb pool (arm asker 42 "已经发布" (addUTCTime (-1) observedAt))
    _ <- withDb pool (admitDueTimeMonitors observedAt)
    claimAt <- getCurrentTime
    [claimed] <- withDb pool (claimAtTime "cancel-race-worker" claimAt)
    queued <-
      withDb pool $
        enqueueOutbound
          OutboundDraft
            { legacyConversationId = 42,
              transcriptKind = "chat",
              sourceCanonicalMessageId = Nothing,
              canonicalBody = Body [NText "⏰ 提醒：已经发布"],
              replyToCanonicalMessageId = Nothing,
              turnOutputLink = Nothing,
              monitorFireId = Just claimed.cmfFireId
            }
    withDb pool (cancelMonitor (conversationScopeFor (GroupId 42)) monitor.mrMonitorOrdinal)
      `shouldReturn` True
    withDb
      pool
      ( completeCannedMonitorFire
          "cancel-race-worker"
          claimed.cmfFireId
          (Just queued.canonicalMessageId)
          Nothing
      )
      `shouldReturn` False
    state <-
      withDb pool $
        query
          "SELECT f.admission_state, f.outbound_canonical_message_id, m.status, m.fire_count \
          \ FROM monitor_fires f JOIN monitors m USING (monitor_id) WHERE f.fire_id=?"
          (Only claimed.cmfFireId)
    (state :: [(Text, Maybe Int64, Text, Int64)])
      `shouldBe` [("dispatched", Just queued.canonicalMessageId.unCanonicalMessageId, "cancelled", 1)]

  it "acknowledges a recurring occurrence and rearms the same monitor cleanly" $ do
    truncateAll pool
    asker <- seedConversation pool 5301 42 7
    observedAt <- getCurrentTime
    monitor <-
      withDb pool $
        armCannedTimeMonitor
          (GroupId 42)
          (PrincipalId asker)
          Nothing
          "站起来"
          (Just "0 * * * *")
          (addUTCTime (-1) observedAt)
    _ <- withDb pool (admitDueTimeMonitors observedAt)
    claimAt <- getCurrentTime
    [first] <- withDb pool (claimAtTime "recurring-worker" claimAt)
    withDb
      pool
      (recordMonitorFireFailure "recurring-worker" first.cmfFireId "temporary" (Just claimAt))
      `shouldReturn` True
    [retry] <- withDb pool (claimAtTime "recurring-worker" (addUTCTime 1 claimAt))
    retry.cmfDeliveryAttempts `shouldBe` 1
    let nextFire = addUTCTime 3600 claimAt
    withDb
      pool
      (completeCannedMonitorFire "recurring-worker" retry.cmfFireId Nothing (Just nextFire))
      `shouldReturn` True

    [rearmed] <- withDb pool (listCannedTimeMonitors (conversationScopeFor (GroupId 42)))
    rearmed.tmRef `shouldBe` monitor
    rearmed.tmFireCount `shouldBe` 1
    rearmed.tmNextFireAt `shouldBeWithinMicros` nextFire
    rearmed.tmDeliveryAttempts `shouldBe` 0
    rearmed.tmNextAttemptAt `shouldBe` Nothing
    rearmed.tmLastError `shouldBe` Nothing
    rearmed.tmParkedAt `shouldBe` Nothing
  where
    arm asker group body fireAt =
      armCannedTimeMonitor
        (GroupId group)
        (PrincipalId asker)
        Nothing
        body
        Nothing
        fireAt

    claimAtTime owner now =
      claimCannedMonitorFires owner now (addUTCTime 60 now) 10

parkThroughFive :: DbPool -> Text -> MonitorFireId -> UTCTime -> Int -> IO ()
parkThroughFive pool owner fireId now failedAttempt = do
  let retryAt = if failedAttempt >= 5 then Nothing else Just now
  withDb pool (recordMonitorFireFailure owner fireId ("failure " <> showText failedAttempt) retryAt)
    `shouldReturn` True
  if failedAttempt >= 5
    then pure ()
    else do
      let next = addUTCTime 1 now
      [claimed] <-
        withDb pool $
          claimCannedMonitorFires owner next (addUTCTime 60 next) 10
      claimed.cmfDeliveryAttempts `shouldBe` failedAttempt
      parkThroughFive pool owner fireId next (failedAttempt + 1)

seedConversation :: DbPool -> Int64 -> Int64 -> Int64 -> IO Int64
seedConversation pool messageId groupId userId = do
  _ <- insertRawMessage pool messageId groupId userId 99 testTime Nothing "set me a reminder"
  rows <-
    withDb pool $
      query
        "SELECT principal_id FROM principal_identities WHERE native_user_id=?"
        (Only (showText userId))
  case rows :: [Only Int64] of
    Only principal : _ -> pure principal
    [] -> expectationFailure "seeded asker has no principal" >> pure 0

showText :: (Show a) => a -> Text
showText = T.pack . show

shouldBeWithinMicros :: UTCTime -> UTCTime -> Expectation
shouldBeWithinMicros actual expected =
  abs (diffUTCTime actual expected) `shouldSatisfy` (< 0.000001)
