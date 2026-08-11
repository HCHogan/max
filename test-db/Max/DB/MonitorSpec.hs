module Max.DB.MonitorSpec (spec) where

import Control.Concurrent (newEmptyMVar, takeMVar, tryPutMVar)
import Control.Concurrent.Async (async, concurrently, wait)
import Control.Monad (forM, forM_, (>=>))
import Data.Int (Int64)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes, isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime, addUTCTime, diffUTCTime, getCurrentTime)
import Database.PostgreSQL.Simple (Only (..))
import Effectful (liftIO)
import Effectful.PostgreSQL (execute, query)
import Helpers (insertRawMessage, insertRawMessageWithClass, testTime, truncateAll, withDb)
import Max.ConversationScope (conversationScopeFor)
import Max.DB.AgentTurn
  ( AgentTurnRecovery (..),
    AgentTurnTerminal (TurnSucceeded),
    ReclaimedTurns (..),
    finishAgentTurn,
    reclaimInterruptedTurns,
    startAgentTurn,
  )
import Max.DB.Connection (DbPool)
import Max.DB.Monitor
  ( CannedMonitorFire (..),
    ElaboratedMonitorFire (..),
    MonitorArmError (..),
    TimeMonitor (..),
    admitElaboratedMonitorTurn,
    admitDueTimeMonitors,
    armCannedTimeMonitor,
    armElaboratedTimeMonitor,
    armLedgerMatchMonitor,
    cancelMonitor,
    claimCannedMonitorFires,
    claimElaboratedMonitorFires,
    completeCannedMonitorFire,
    listArmedMonitors,
    listCannedTimeMonitors,
    loadAdmittedMonitorFire,
    lookupMonitorFireOutput,
    nextMonitorDeadline,
    reclaimExpiredMonitorFireClaims,
    recordMonitorFireFailure,
  )
import Max.DB.Notify (WorkChannel (MonitorWork), claimOrWaitUntil)
import Max.IR (Body (..), Node (NText))
import Max.Monitor.Types
  ( LedgerMatchSpec (..),
    MonitorFireId,
    MonitorOrdinal (..),
    MonitorRef (..),
  )
import Max.Platform.Envelope (IngestClass (Backfill))
import Max.Platform.Store
  ( EnqueuedOutbound (..),
    OutboundDraft (..),
    enqueueOutbound,
    recordInternalMessage,
  )
import Max.Platform.Types (CanonicalMessageId (..), PrincipalId (..))
import Max.Turn.Types (AgentTurnId (..), AgentTurnRef (..))
import OneBot.Types (GroupId (..))
import System.Timeout qualified
import Test.Hspec

spec :: DbPool -> Spec
spec pool = describe "Max.DB.Monitor TimeCron + canned" $ do
  it "wakes the cross-process scheduler from durable PostgreSQL work notification" $ do
    truncateAll pool
    principal <- seedConversation pool 4901 41 6
    subscribed <- newEmptyMVar
    waiter <-
      async $
        withDb pool $
          claimOrWaitUntil 2_000_000 MonitorWork $ do
            _ <- liftIO (tryPutMVar subscribed ())
            query
              "SELECT m.monitor_id FROM monitors m JOIN conversations c USING (conversation_id) \
              \ WHERE c.legacy_group_id=41 AND m.goal_text='wake scheduler'"
              ()
    takeMVar subscribed
    now <- getCurrentTime
    monitor <- withDb pool (armCannedTimeMonitor (GroupId 41) (PrincipalId principal) Nothing "wake scheduler" Nothing (addUTCTime 60 now))
    woke <- System.Timeout.timeout 1_000_000 (wait waiter)
    woke `shouldBe` Just [Only monitor.mrMonitorId]

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
    deadline <- requireJustIO "monitor deadline" =<< withDb pool (nextMonitorDeadline now)
    deadline `shouldBeWithinMicros` addUTCTime 60 now

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

  it "persists trusted ingest provenance and lets only a new live inbound row admit one LedgerMatch edge" $ do
    truncateAll pool
    principal <- seedConversation pool 6001 61 701
    armingTurn <- withDb pool (startAgentTurn (GroupId 61) (CanonicalMessageId 1) (PrincipalId principal))
    now <- getCurrentTime
    monitor <-
      requireRight "arm ledger monitor" =<<
        withDb
          pool
          ( armLedgerMatchMonitor
              (GroupId 61)
              (PrincipalId principal)
              armingTurn
              "summarize the launch update"
              (LedgerMatchSpec Nothing (Just "launch") Nothing False)
              60
              (addUTCTime 86400 now)
              3
              (Map.fromList [("inspect_source", "grant-a"), ("context_search", "grant-b")])
          )
    withDb pool (finishAgentTurn armingTurn TurnSucceeded 1 Nothing Nothing)

    backfillCanonical <-
      insertRawMessageWithClass pool Backfill 6002 61 701 99 now Nothing "LAUNCH imported history"
    provenance <-
      withDb pool $
        query
          "SELECT pe.ingest_class, m.ingest_class FROM platform_events pe \
          \ JOIN messages m USING (canonical_message_id) WHERE m.canonical_message_id=?"
          (Only backfillCanonical)
    (provenance :: [(Text, Text)]) `shouldBe` [("backfill", "backfill")]
    fireCount pool monitor `shouldReturn` 0

    liveCanonical <- insertRawMessage pool 6003 61 701 99 now Nothing "The LAUNCH is ready"
    insertRawMessage pool 6003 61 701 99 now Nothing "The LAUNCH is ready"
      `shouldReturn` liveCanonical
    fireCount pool monitor `shouldReturn` 1
    liveProvenance <-
      withDb pool $
        query
          "SELECT pe.ingest_class, m.ingest_class FROM platform_events pe \
          \ JOIN messages m USING (canonical_message_id) WHERE m.canonical_message_id=?"
          (Only liveCanonical)
    (liveProvenance :: [(Text, Text)]) `shouldBe` [("live_delivery", "live_delivery")]

    let matchingDraft =
          OutboundDraft
            { legacyConversationId = 61,
              transcriptKind = "chat",
              sourceCanonicalMessageId = Nothing,
              canonicalBody = Body [NText "launch from max"],
              replyToCanonicalMessageId = Nothing,
              turnOutputLink = Nothing,
              monitorFireId = Nothing
            }
    _ <- withDb pool (enqueueOutbound matchingDraft)
    _ <- withDb pool (recordInternalMessage matchingDraft {canonicalBody = Body [NText "launch silently"]})
    fireCount pool monitor `shouldReturn` 1

    [claimed] <-
      withDb pool $
        claimElaboratedMonitorFires "ledger-worker" now (addUTCTime 60 now) 10
    claimed.emfTriggerCanonicalMessage `shouldBe` Just (CanonicalMessageId liveCanonical)
    claimed.emfTriggerEvidence `shouldSatisfy` T.isInfixOf "LAUNCH is ready"
    claimed.emfEffectToolGrants
      `shouldBe` Map.fromList [("inspect_source", "grant-a"), ("context_search", "grant-b")]

  it "serializes cooldown and admits/reclaims exactly one ordinary turn for a committed fire" $ do
    truncateAll pool
    principal <- seedConversation pool 6101 62 702
    armingTurn <- withDb pool (startAgentTurn (GroupId 62) (CanonicalMessageId 1) (PrincipalId principal))
    now <- getCurrentTime
    monitor <-
      requireRight "arm concurrent ledger monitor" =<<
        withDb
          pool
          ( armLedgerMatchMonitor
              (GroupId 62)
              (PrincipalId principal)
              armingTurn
              "handle one ship event"
              (LedgerMatchSpec Nothing (Just "ship") Nothing False)
              60
              (addUTCTime 86400 now)
              20
              (Map.singleton "context_search" "grant-a")
          )
    withDb pool (finishAgentTurn armingTurn TurnSucceeded 1 Nothing Nothing)

    _ <-
      concurrently
        (insertRawMessage pool 6102 62 702 99 now Nothing "ship alpha")
        (insertRawMessage pool 6103 62 702 99 now Nothing "ship beta")
    fireCount pool monitor `shouldReturn` 1
    [claimed] <-
      withDb pool $
        claimElaboratedMonitorFires "admitter-a" now (addUTCTime 60 now) 10
    withDb pool (claimElaboratedMonitorFires "admitter-b" now (addUTCTime 60 now) 10)
      `shouldReturn` []
    admitted <- requireJustIO "admitted monitor turn" =<< withDb pool (admitElaboratedMonitorTurn "admitter-a" claimed.emfFireId Nothing)
    withDb pool (admitElaboratedMonitorTurn "admitter-a" claimed.emfFireId Nothing)
      `shouldReturn` Nothing
    withDb pool (loadAdmittedMonitorFire claimed.emfFireId)
      `shouldReturn` Just claimed {emfClaimOwner = Nothing, emfAdmittedTurn = Just admitted}

    edges <-
      withDb pool $
        query
          "SELECT from_turn_id, to_turn_id, edge_kind FROM turn_edges WHERE from_turn_id=?"
          (Only admitted.atrTurnId)
    (edges :: [(Int64, Int64, Text)])
      `shouldBe` [(unTurn admitted, unTurn armingTurn, "fork-from")]

    firstBoot <- withDb pool (reclaimInterruptedTurns "monitor-boot-a")
    firstBoot.rrRecoveries
      `shouldBe`
        [ AgentTurnRecovery
            admitted
            (GroupId 62)
            claimed.emfTriggerCanonicalMessage
            (Just claimed.emfFireId)
        ]
    withDb pool (reclaimInterruptedTurns "monitor-boot-a")
      `shouldReturn` ReclaimedTurns 0 0 0 []
    secondBoot <- withDb pool (reclaimInterruptedTurns "monitor-boot-b")
    map (.atrRecoveryTurn) secondBoot.rrRecoveries `shouldBe` [admitted]
    turnCount pool 62 `shouldReturn` 2

    otherPrincipal <- seedConversation pool 6104 63 703
    otherTurn <- withDb pool (startAgentTurn (GroupId 63) (CanonicalMessageId 4) (PrincipalId otherPrincipal))
    withDb pool
      (execute "UPDATE monitor_fires SET admitted_turn_id=? WHERE fire_id=?" (otherTurn.atrTurnId, claimed.emfFireId))
      `shouldThrow` anyException

  it "enforces condition/total caps, a durable hourly budget, and the one-shot TimeCron bypass" $ do
    truncateAll pool
    principal <- seedConversation pool 6201 64 704
    armingTurn <- withDb pool (startAgentTurn (GroupId 64) (CanonicalMessageId 1) (PrincipalId principal))
    now <- getCurrentTime
    let armLedger index =
          withDb
            pool
            ( armLedgerMatchMonitor
                (GroupId 64)
                (PrincipalId principal)
                armingTurn
                ("condition " <> showText index)
                (LedgerMatchSpec Nothing (Just ("match-" <> showText index)) Nothing False)
                0
                (addUTCTime 86400 now)
                20
                (Map.singleton "context_search" "grant-a")
            )
    armedConditions <- forM [1 .. 5 :: Int] (armLedger >=> requireRight "arm condition")
    map (.mrMonitorOrdinal) armedConditions
      `shouldBe` map MonitorOrdinal [1 .. 5]
    armLedger (6 :: Int) `shouldReturn` Left ConditionMonitorCapReached

    let future = addUTCTime 86400 now
        armTime index fireAt =
          withDb
            pool
            ( armElaboratedTimeMonitor
                (GroupId 64)
                (PrincipalId principal)
                armingTurn
                ("time " <> showText index)
                Nothing
                fireAt
                (Map.singleton "context_search" "grant-a")
            )
    forM_ [1 .. 15 :: Int] $ \index -> armTime index future >>= requireRight "arm time"
    armTime (16 :: Int) future `shouldReturn` Left ArmedMonitorCapReached
    length <$> withDb pool (listArmedMonitors (conversationScopeFor (GroupId 64)))
      `shouldReturn` 20

    -- Use a fresh conversation to exercise five already-admitted occurrences
    -- without the cap fixture above obscuring the per-group budget.
    budgetPrincipal <- seedConversation pool 6301 65 705
    budgetArming <- withDb pool (startAgentTurn (GroupId 65) (CanonicalMessageId 2) (PrincipalId budgetPrincipal))
    budgetMonitor <-
      requireRight "arm budget ledger" =<<
        withDb
          pool
          ( armLedgerMatchMonitor
              (GroupId 65)
              (PrincipalId budgetPrincipal)
              budgetArming
              "budgeted continuation"
              (LedgerMatchSpec Nothing (Just "budget-hit") Nothing False)
              0
              (addUTCTime 86400 now)
              10
              (Map.singleton "context_search" "grant-a")
          )
    withDb pool (finishAgentTurn budgetArming TurnSucceeded 1 Nothing Nothing)
    forM_ [6302 .. 6306] $ \messageId ->
      insertRawMessage pool messageId 65 705 99 now Nothing "budget-hit"
    fireCount pool budgetMonitor `shouldReturn` 5
    claimed <- withDb pool (claimElaboratedMonitorFires "budget-worker" now (addUTCTime 60 now) 10)
    admitted <- catMaybes <$> mapM (\fire -> withDb pool (admitElaboratedMonitorTurn "budget-worker" fire.emfFireId Nothing)) claimed
    length admitted `shouldBe` 4
    budgetStates pool budgetMonitor `shouldReturn` [(4, 1)]

    oneShot <- requireRight "arm one-shot" =<< armTimeFor pool budgetPrincipal budgetArming now
    withDb pool (admitDueTimeMonitors now) `shouldReturn` 1
    [clockFire] <- withDb pool (claimElaboratedMonitorFires "clock-worker" now (addUTCTime 60 now) 10)
    clockFire.emfMonitor `shouldBe` oneShot
    clockTurn <- withDb pool (admitElaboratedMonitorTurn "clock-worker" clockFire.emfFireId Nothing)
    clockTurn `shouldSatisfy` isJust
    monitorState pool oneShot `shouldReturn` [("fired", 1)]

    _ <-
      withDb pool $
        execute
          "UPDATE monitor_fires SET dispatched_at=now() - interval '61 minutes' \
          \ WHERE monitor_id=? AND admission_state='dispatched'"
          (Only budgetMonitor.mrMonitorId)
    [released] <- withDb pool (claimElaboratedMonitorFires "budget-worker-2" now (addUTCTime 60 now) 10)
    finalTurn <- withDb pool (admitElaboratedMonitorTurn "budget-worker-2" released.emfFireId Nothing)
    finalTurn `shouldSatisfy` isJust
    budgetStates pool budgetMonitor `shouldReturn` [(5, 0)]

  it "expires world watchers at TTL/max-fire boundaries and quietly closes a missing arming principal" $ do
    truncateAll pool
    principal <- seedConversation pool 6401 66 706
    armingTurn <- withDb pool (startAgentTurn (GroupId 66) (CanonicalMessageId 1) (PrincipalId principal))
    now <- getCurrentTime
    maxOne <-
      requireRight "arm max-one monitor" =<<
        withDb
          pool
          ( armLedgerMatchMonitor
              (GroupId 66)
              (PrincipalId principal)
              armingTurn
              "only once"
              (LedgerMatchSpec Nothing (Just "one-hit") Nothing False)
              0
              (addUTCTime 86400 now)
              1
              (Map.singleton "context_search" "grant-a")
          )
    _ <- insertRawMessage pool 6402 66 706 99 now Nothing "one-hit"
    monitorReason pool maxOne `shouldReturn` [("expired", Just "max_fire_count", 1)]
    length <$> withDb pool (claimElaboratedMonitorFires "max-one-worker" now (addUTCTime 60 now) 10)
      `shouldReturn` 1

    ttlMonitor <-
      requireRight "arm expired TTL monitor" =<<
        withDb
          pool
          ( armLedgerMatchMonitor
              (GroupId 66)
              (PrincipalId principal)
              armingTurn
              "already expired"
              (LedgerMatchSpec Nothing (Just "never") Nothing False)
              0
              (addUTCTime (-1) now)
              2
              (Map.singleton "context_search" "grant-a")
          )
    _ <- withDb pool (admitDueTimeMonitors now)
    monitorReason pool ttlMonitor `shouldReturn` [("expired", Just "ttl_expired", 0)]

    ownerless <-
      requireRight "arm ownerless monitor" =<<
        withDb
          pool
          ( armElaboratedTimeMonitor
              (GroupId 66)
              (PrincipalId principal)
              armingTurn
              "must close quietly"
              Nothing
              (addUTCTime 3600 now)
              (Map.singleton "context_search" "grant-a")
          )
    _ <-
      withDb pool $
        execute "UPDATE monitors SET armed_by_principal_id=NULL WHERE monitor_id=?" (Only ownerless.mrMonitorId)
    _ <- withDb pool (admitDueTimeMonitors now)
    monitorReason pool ownerless
      `shouldReturn` [("expired", Just "arming_principal_missing", 0)]
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

requireRight :: (Show e) => String -> Either e a -> IO a
requireRight label = \case
  Right value -> pure value
  Left err -> expectationFailure (label <> ": " <> show err) >> error label

requireJustIO :: String -> Maybe a -> IO a
requireJustIO label = \case
  Just value -> pure value
  Nothing -> expectationFailure ("missing " <> label) >> error label

fireCount :: DbPool -> MonitorRef -> IO Int64
fireCount pool monitor = do
  rows <-
    withDb pool $
      query "SELECT count(*) FROM monitor_fires WHERE monitor_id=?" (Only monitor.mrMonitorId)
  case rows :: [Only Int64] of
    [Only count] -> pure count
    _ -> expectationFailure "fire count query returned no row" >> pure (-1)

turnCount :: DbPool -> Int64 -> IO Int64
turnCount pool groupId = do
  rows <-
    withDb pool $
      query
        "SELECT count(*) FROM agent_turns t JOIN conversations c USING (conversation_id) \
        \ WHERE c.legacy_group_id=?"
        (Only groupId)
  case rows :: [Only Int64] of
    [Only count] -> pure count
    _ -> expectationFailure "turn count query returned no row" >> pure (-1)

budgetStates :: DbPool -> MonitorRef -> IO [(Int64, Int64)]
budgetStates pool monitor =
  withDb pool $
    query
      "SELECT count(*) FILTER (WHERE admission_state='dispatched'), \
      \       count(*) FILTER (WHERE admission_state='pending' AND cancelled_at IS NULL) \
      \ FROM monitor_fires WHERE monitor_id=?"
      (Only monitor.mrMonitorId)

monitorState :: DbPool -> MonitorRef -> IO [(Text, Int64)]
monitorState pool monitor =
  withDb pool $
    query "SELECT status, fire_count FROM monitors WHERE monitor_id=?" (Only monitor.mrMonitorId)

monitorReason :: DbPool -> MonitorRef -> IO [(Text, Maybe Text, Int64)]
monitorReason pool monitor =
  withDb pool $
    query
      "SELECT status, status_reason, fire_count FROM monitors WHERE monitor_id=?"
      (Only monitor.mrMonitorId)

armTimeFor :: DbPool -> Int64 -> AgentTurnRef -> UTCTime -> IO (Either MonitorArmError MonitorRef)
armTimeFor pool principal armingTurn now =
  withDb
    pool
    ( armElaboratedTimeMonitor
        (GroupId 65)
        (PrincipalId principal)
        armingTurn
        "one-shot bypass"
        Nothing
        (addUTCTime (-1) now)
        (Map.singleton "context_search" "grant-a")
    )

unTurn :: AgentTurnRef -> Int64
unTurn (AgentTurnRef (AgentTurnId turnId) _) = turnId
