module Max.DB.MonitorSpec (spec) where

import Control.Concurrent (newEmptyMVar, takeMVar, tryPutMVar)
import Control.Concurrent.Async (async, concurrently, wait)
import Control.Monad (forM, forM_, (>=>))
import Data.Either (isRight, rights)
import Data.Int (Int64)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime, addUTCTime, diffUTCTime, getCurrentTime, utc)
import Database.PostgreSQL.Simple (Only (..))
import Effectful (Eff, IOE, liftIO, (:>))
import Effectful.PostgreSQL (WithConnection, execute, query)
import Helpers (insertRawMessage, insertRawMessageWithClass, testTime, truncateAll, withDb, withDbLog)
import Max.ConversationScope (conversationScopeFor)
import Max.DB.AgentTurn
  ( AgentTurnTerminal (TurnSucceeded),
    finishAgentTurn,
    startAgentTurn,
  )
import Max.DB.Connection (DbPool)
import Max.DB.Monitor
  ( CannedMonitorFire (..),
    ElaboratedMonitorFire (..),
    MonitorArmError (..),
    TimeMonitor (..),
    admitDueTimeMonitors,
    armCannedTimeMonitor,
    armElaboratedTimeMonitor,
    armLedgerMatchMonitor,
    beginCannedMonitorFire,
    finishCannedMonitorFire,
    interruptMonitorFires,
    listArmedMonitors,
    listCannedTimeMonitors,
    lookupMonitorFireOutput,
    nextMonitorDeadline,
    pendingCannedMonitorFires,
    pendingElaboratedMonitorFires,
  )
import Max.DB.Monitor.Admission
import Max.DB.Monitor.Control qualified as Control
import Max.DB.Notify (WorkChannel (MonitorWork), waitForWorkUntil)
import Max.DB.Transaction (withTransaction)
import Max.IR (Body (..), Node (NMention, NText))
import Max.Monitor (deliveryBody)
import Max.Monitor.Control qualified as ControlTypes
import Max.Monitor.Types
  ( LedgerMatchSpec (..),
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
import Max.Task.Types qualified as Job
import Max.Turn.Types (AgentTurnRef (..))
import OneBot.Types (GroupId (..))
import System.Timeout qualified
import Test.Hspec

spec :: DbPool -> Spec
spec pool = describe "Max.DB.Monitor TimeCron + canned" $ do
  it "resolves mentions in reminder text without adding an initiator mention" $ do
    truncateAll pool
    _ <- insertRawMessage pool 9001 900 1 42 testTime (Just "requester") "hello"
    [Only principal] <- withDb pool $ query "SELECT author_principal_id FROM messages WHERE group_id=900 LIMIT 1" ()
    (body, replyTo) <- withDbLog pool $ deliveryBody (GroupId 900) ("[mention#" <> T.pack (show (principal :: Int64)) <> "] I love you")
    replyTo `shouldBe` Nothing
    length [() | NMention _ _ <- body.nodes] `shouldBe` 1
    T.concat [text | NText text <- body.nodes] `shouldBe` "⏰ 提醒： I love you"
    (plain, _) <- withDbLog pool $ deliveryBody (GroupId 900) "喝水"
    plain `shouldBe` Body [NText "⏰ 提醒：喝水"]

  it "wakes the scheduler when a definition changes" $ do
    truncateAll pool
    principal <- seedConversation pool 4901 41 6
    subscribed <- newEmptyMVar
    waiter <-
      async $
        withDb pool $
          waitForWorkUntil 2_000_000 MonitorWork $ do
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
    withDb pool (withTransaction (Control.controlMonitor 43 otherAsker False 2 Control.CancelMonitor False))
      `shouldReturn` Left ControlTypes.MonitorNotFound
    withDb pool (withTransaction (Control.controlMonitor 42 asker False 2 Control.CancelMonitor False))
      `shouldReturn` Right (ControlTypes.MonitorControlReceipt 1 False True, [])

    -- Admission and cancellation serialize on the monitor row. Whichever
    -- wins, cancellation cannot leave a live fire behind.
    racedAsker <- seedConversation pool 5003 44 9
    raced <- withDb pool (arm racedAsker 44 "raced" (addUTCTime (-1) now))
    (_, cancelled) <-
      concurrently
        (withDb pool (admitDueTimeMonitors now))
        (withDb pool (withTransaction (Control.controlMonitor 44 racedAsker False raced.mrMonitorOrdinal.unMonitorOrdinal Control.CancelMonitor False)))
    cancelled `shouldBe` Right (ControlTypes.MonitorControlReceipt 1 False True, [])
    active <-
      withDb pool $
        query
          "SELECT count(*) FROM monitor_fires WHERE monitor_id=? \
          \ AND admission_state='pending' AND cancelled_at IS NULL"
          (Only raced.mrMonitorId)
    (active :: [Only Int64]) `shouldBe` [Only 0]

  it "consumes a calendar trigger before publication and never replays it on restart" $ do
    truncateAll pool
    asker <- seedConversation pool 5101 42 7
    now <- getCurrentTime
    _ <- withDb pool (arm asker 42 "喝水" (addUTCTime (-1) now))
    withDb pool (admitDueTimeMonitors now) `shouldReturn` 1
    withDb pool (admitDueTimeMonitors now) `shouldReturn` 0
    [fire] <- withDb pool (pendingCannedMonitorFires 10)
    withDb pool (beginCannedMonitorFire fire.cmfFireId Nothing) `shouldReturn` True
    withDb pool (beginCannedMonitorFire fire.cmfFireId Nothing) `shouldReturn` False
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
              monitorFireId = Just fire.cmfFireId
            }
    withDb pool (interruptMonitorFires utc now) `shouldReturn` 1
    withDb pool (interruptMonitorFires utc now) `shouldReturn` 0
    withDb pool (pendingCannedMonitorFires 10) `shouldReturn` []
    withDb pool (admitDueTimeMonitors now) `shouldReturn` 0
    withDb pool (lookupMonitorFireOutput fire.cmfFireId) `shouldReturn` Just queued.canonicalMessageId

  it "ends unstarted triggers on restart while retaining the next recurring schedule" $ do
    truncateAll pool
    asker <- seedConversation pool 5201 42 7
    now <- getCurrentTime
    _ <- withDb pool (arm asker 42 "one-shot" (addUTCTime (-1) now))
    recurring <- withDb pool (armCannedTimeMonitor (GroupId 42) (PrincipalId asker) Nothing "recurring" (Just "0 * * * *") (addUTCTime (-1) now))
    withDb pool (admitDueTimeMonitors now) `shouldReturn` 2
    withDb pool (interruptMonitorFires utc now) `shouldReturn` 2
    withDb pool (pendingCannedMonitorFires 10) `shouldReturn` []
    [scheduled] <- withDb pool (listCannedTimeMonitors (conversationScopeFor (GroupId 42)))
    scheduled.tmRef `shouldBe` recurring
    scheduled.tmNextFireAt `shouldSatisfy` (> now)
    withDb pool (admitDueTimeMonitors scheduled.tmNextFireAt) `shouldReturn` 1
    [next] <- withDb pool (pendingCannedMonitorFires 10)
    next.cmfMonitor `shouldBe` recurring

  it "cancels a consumed trigger before publication" $ do
    truncateAll pool
    asker <- seedConversation pool 5251 42 7
    now <- getCurrentTime
    monitor <- withDb pool (arm asker 42 "reminder" (addUTCTime (-1) now))
    _ <- withDb pool (admitDueTimeMonitors now)
    [fire] <- withDb pool (pendingCannedMonitorFires 10)
    withDb pool (beginCannedMonitorFire fire.cmfFireId Nothing) `shouldReturn` True
    withDb pool (withTransaction (Control.controlMonitor 42 asker False monitor.mrMonitorOrdinal.unMonitorOrdinal Control.CancelMonitor False))
      `shouldReturn` Right (ControlTypes.MonitorControlReceipt 1 False True, [])
    withDb
      pool
      ( enqueueOutbound
          OutboundDraft
            { legacyConversationId = 42,
              transcriptKind = "chat",
              sourceCanonicalMessageId = Nothing,
              canonicalBody = Body [NText "late"],
              replyToCanonicalMessageId = Nothing,
              turnOutputLink = Nothing,
              monitorFireId = Just fire.cmfFireId
            }
      )
      `shouldThrow` anyErrorCall

  it "records a publication failure without scheduling another delivery" $ do
    truncateAll pool
    asker <- seedConversation pool 5301 42 7
    now <- getCurrentTime
    monitor <- withDb pool (armCannedTimeMonitor (GroupId 42) (PrincipalId asker) Nothing "recurring" (Just "0 * * * *") (addUTCTime (-1) now))
    _ <- withDb pool (admitDueTimeMonitors now)
    [fire] <- withDb pool (pendingCannedMonitorFires 10)
    let next = addUTCTime 3600 now
    withDb pool (beginCannedMonitorFire fire.cmfFireId (Just next)) `shouldReturn` True
    withDb pool (finishCannedMonitorFire fire.cmfFireId (Left "send outcome uncertain"))
    withDb pool (pendingCannedMonitorFires 10) `shouldReturn` []
    [scheduled] <- withDb pool (listCannedTimeMonitors (conversationScopeFor (GroupId 42)))
    scheduled.tmRef `shouldBe` monitor
    scheduled.tmNextFireAt `shouldBeWithinMicros` next
    withDb pool (query "SELECT last_error FROM monitor_fires WHERE fire_id=?" (Only fire.cmfFireId)) `shouldReturn` [Only ("send outcome uncertain" :: Text)]

  it "persists trusted ingest provenance and lets only a new live inbound row admit one LedgerMatch edge" $ do
    truncateAll pool
    principal <- seedConversation pool 6001 61 701
    armingTurn <- withDb pool (startAgentTurn (GroupId 61) (CanonicalMessageId 1) (PrincipalId principal))
    now <- getCurrentTime
    monitor <-
      requireRight "arm ledger monitor"
        =<< withDb
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
    withDb pool (finishAgentTurn armingTurn TurnSucceeded 1 Nothing)

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
        pendingElaboratedMonitorFires now 10
    claimed.emfTriggerCanonicalMessage `shouldBe` Just (CanonicalMessageId liveCanonical)
    claimed.emfTriggerEvidence `shouldSatisfy` T.isInfixOf "LAUNCH is ready"
    claimed.emfEffectToolGrants
      `shouldBe` Map.fromList [("inspect_source", "grant-a"), ("context_search", "grant-b")]

  it "serializes cooldown and admits a committed fire only once without restart continuation" $ do
    truncateAll pool
    principal <- seedConversation pool 6101 62 702
    armingTurn <- withDb pool (startAgentTurn (GroupId 62) (CanonicalMessageId 1) (PrincipalId principal))
    now <- getCurrentTime
    monitor <-
      requireRight "arm concurrent ledger monitor"
        =<< withDb
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
    withDb pool (finishAgentTurn armingTurn TurnSucceeded 1 Nothing)

    _ <-
      concurrently
        (insertRawMessage pool 6102 62 702 99 now Nothing "ship alpha")
        (insertRawMessage pool 6103 62 702 99 now Nothing "ship beta")
    fireCount pool monitor `shouldReturn` 1
    [claimed] <-
      withDb pool $
        pendingElaboratedMonitorFires now 10
    MonitorTaskAdmitted identifier job <- requireRight "admitted monitor job" =<< withDb pool (admitFire claimed Nothing)
    withDb pool (admitFire claimed Nothing) `shouldReturn` Right MonitorAlreadyDispatched
    job.group `shouldBe` GroupId 62
    job.principal `shouldBe` PrincipalId principal
    job.grants `shouldBe` Map.empty
    job.monitor `shouldBe` Just (Job.JobMonitor monitor.mrMonitorId claimed.emfFireId)
    withDb pool (query "SELECT task_id FROM monitor_fires WHERE fire_id=?" (Only claimed.emfFireId))
      `shouldReturn` [Only identifier]
    withDb pool (query "SELECT count(*) FROM durable_tasks" ()) `shouldReturn` [Only (0 :: Int64)]
    turnCount pool 62 `shouldReturn` 1

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
    armedConditions <- forM [1 .. 25 :: Int] (armLedger >=> requireRight "arm condition")
    map (.mrMonitorOrdinal) armedConditions
      `shouldBe` map MonitorOrdinal [1 .. 25]
    armLedger (26 :: Int) `shouldReturn` Left ConditionMonitorCapReached

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
    forM_ [1 .. 75 :: Int] $ \index -> armTime index future >>= requireRight "arm time"
    armTime (76 :: Int) future `shouldReturn` Left ArmedMonitorCapReached
    length <$> withDb pool (listArmedMonitors (conversationScopeFor (GroupId 64)))
      `shouldReturn` 100

    -- Use a fresh conversation to exercise five already-admitted occurrences
    -- without the cap fixture above obscuring the per-group budget.
    budgetPrincipal <- seedConversation pool 6301 65 705
    budgetArming <- withDb pool (startAgentTurn (GroupId 65) (CanonicalMessageId 2) (PrincipalId budgetPrincipal))
    budgetMonitor <-
      requireRight "arm budget ledger"
        =<< withDb
          pool
          ( armLedgerMatchMonitor
              (GroupId 65)
              (PrincipalId budgetPrincipal)
              budgetArming
              "budgeted continuation"
              (LedgerMatchSpec Nothing (Just "budget-hit") Nothing False)
              0
              (addUTCTime 86400 now)
              100
              (Map.singleton "context_search" "grant-a")
          )
    withDb pool (finishAgentTurn budgetArming TurnSucceeded 1 Nothing)
    _ <- withDb pool (execute "UPDATE monitors SET overlap_policy='queue',queue_limit=40 WHERE monitor_id=?" (Only budgetMonitor.mrMonitorId))
    forM_ [6302 .. 6322] $ \messageId ->
      insertRawMessage pool messageId 65 705 99 now Nothing "budget-hit"
    fireCount pool budgetMonitor `shouldReturn` 21
    claimed <- withDb pool (pendingElaboratedMonitorFires now 50)
    admitted <- rights <$> mapM (\fire -> withDb pool (admitFire fire Nothing)) claimed
    length admitted `shouldBe` 20
    budgetStates pool budgetMonitor `shouldReturn` [(20, 1)]

    oneShot <- requireRight "arm one-shot" =<< armTimeFor pool budgetPrincipal budgetArming now
    withDb pool (admitDueTimeMonitors now) `shouldReturn` 1
    [clockFire] <- withDb pool (pendingElaboratedMonitorFires now 10)
    clockFire.emfMonitor `shouldBe` oneShot
    clockTurn <- withDb pool (admitFire clockFire Nothing)
    clockTurn `shouldSatisfy` isRight
    monitorState pool oneShot `shouldReturn` [("fired", 1)]

    _ <-
      withDb pool $
        execute
          "UPDATE monitor_fires SET dispatched_at=now() - interval '61 minutes' \
          \ WHERE monitor_id=? AND admission_state='dispatched'"
          (Only budgetMonitor.mrMonitorId)
    [released] <- withDb pool (pendingElaboratedMonitorFires now 10)
    finalTurn <- withDb pool (admitFire released Nothing)
    finalTurn `shouldSatisfy` isRight
    budgetStates pool budgetMonitor `shouldReturn` [(21, 0)]

  it "expires world watchers at TTL/max-fire boundaries and quietly closes a missing arming principal" $ do
    truncateAll pool
    principal <- seedConversation pool 6401 66 706
    armingTurn <- withDb pool (startAgentTurn (GroupId 66) (CanonicalMessageId 1) (PrincipalId principal))
    now <- getCurrentTime
    maxOne <-
      requireRight "arm max-one monitor"
        =<< withDb
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
    length <$> withDb pool (pendingElaboratedMonitorFires now 10)
      `shouldReturn` 1

    ttlMonitor <-
      requireRight "arm expired TTL monitor"
        =<< withDb
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
      requireRight "arm ownerless monitor"
        =<< withDb
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

-- The current admission boundary validates the claimed fire's seed and frozen
-- authority, and allocates a non-reusable job handle.
admitFire :: (WithConnection :> es, IOE :> es) => ElaboratedMonitorFire -> Maybe UTCTime -> Eff es (Either MonitorAdmissionError MonitorAdmission)
admitFire fire next =
  withTransaction $
    admitMonitorTaskWithin
      fire.emfFireId
      next
      Map.empty
      (maybe 0 (.unCanonicalMessageId) fire.emfSeedCanonicalMessage)
