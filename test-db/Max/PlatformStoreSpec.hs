module Max.PlatformStoreSpec (spec) where

import Control.Concurrent.Async (concurrently)
import Control.Monad (forM_)
import Data.Aeson (Value (..), object, toJSON, (.=))
import Data.ByteString.Char8 qualified as BS
import Data.IORef
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (NominalDiffTime, UTCTime, addUTCTime, getCurrentTime)
import Database.PostgreSQL.Simple (Only (..), execute, query)
import Helpers (resultId, truncateAll, withDb)
import Max.ConversationScope (conversationScopeFor)
import Max.DB.Connection (DbPool, withConn)
import Max.DB.History (HistoryItem (..), fetchForwardChildrenInScope)
import Max.HttpRuntime (httpRuntimeFromManagers)
import Max.IR
import Max.IR.Lower
import Max.Matrix (MatrixConfig (..), matrixDeliveryTransport)
import Max.Platform (PlatformBackend (..))
import Max.Platform.Delivery (DeliveryOperation (..), DeliveryTransport (..), oneBotDeliveryTransport)
import Max.Platform.Delivery.Parts
import Max.Platform.Delivery.Store
import Max.Platform.Envelope (InboundEnvelope (..), IngestClass (LiveDelivery))
import Max.Platform.Store
import Max.Platform.Store qualified as PlatformStore
import Max.Platform.Types
import Max.Util (tshow)
import Network.HTTP.Client qualified as HTTP
import OneBot.Action (Action (..), Response (..))
import OneBot.Types (GroupId (..))
import System.Directory (doesFileExist)
import Test.Hspec

spec :: DbPool -> Spec
spec pool = before_ (truncateAll pool) $ describe "Max.Platform.Store" $ do
  it "promotes an existing QQ endpoint when a configured Matrix mirror attaches" $ do
    qq <-
      withDb pool $
        ensureLegacyEndpoint
          PlatformQQ
          (NativeAccountId "9")
          (NativeConversationId "42")
          ConversationGroup
          42
          textCapabilities
    matrix <-
      withDb pool $
        ensureConfiguredEndpoint
          PlatformMatrix
          (NativeAccountId "@max:example.test")
          (NativeConversationId "!room:example.test")
          ConversationGroup
          EndpointMirror
          (Just 42)
          textCapabilities
    now <- getCurrentTime
    _ <- withDb pool (ingestEnvelope defaultIngestOptions (inbound matrix.endpointId now "mx-existing-qq" "relay me"))
    claims <- claimStartedDeliveries pool "mirror-cutover" 10 30
    fmap (.endpointId) claims `shouldBe` [qq.endpointId]

  -- Both cases above configure the mirror at first registration.  An endpoint
  -- that ran standalone for weeks and is only later named as a mirror keeps
  -- its own conversation unless the rebind is explicit, and the fan-out pairs
  -- endpoints by conversation — so without it the config parses, the log says
  -- "mirror", and nothing is ever relayed.
  it "rebinds an endpoint that ran standalone before it was named as a mirror" $ do
    standalone <-
      withDb pool $
        ensureConfiguredEndpoint
          PlatformIMessage
          (NativeAccountId "mac-account")
          (NativeConversationId "iMessage;+;chat")
          ConversationGroup
          EndpointStandalone
          Nothing
          textCapabilities
    qq <-
      withDb pool $
        ensureLegacyEndpoint
          PlatformQQ
          (NativeAccountId "9")
          (NativeConversationId "42")
          ConversationGroup
          42
          textCapabilities
    rebound <-
      withDb pool $
        ensureConfiguredEndpoint
          PlatformIMessage
          (NativeAccountId "mac-account")
          (NativeConversationId "iMessage;+;chat")
          ConversationGroup
          EndpointMirror
          (Just 42)
          textCapabilities
    -- Same endpoint row, moved: a rebind must not orphan the cursor and the
    -- deliveries that already name this endpoint.
    rebound.endpointId `shouldBe` standalone.endpointId
    now <- getCurrentTime
    _ <- withDb pool (ingestEnvelope defaultIngestOptions (inbound rebound.endpointId now "imsg-after-rebind" "relay me"))
    claims <- claimStartedDeliveries pool "mirror-cutover" 10 30
    fmap (.endpointId) claims `shouldBe` [qq.endpointId]

  it "promotes a QQ endpoint first observed after its Matrix mirror" $ do
    matrix <-
      withDb pool $
        ensureConfiguredEndpoint
          PlatformMatrix
          (NativeAccountId "@max:example.test")
          (NativeConversationId "!room:example.test")
          ConversationGroup
          EndpointMirror
          (Just 42)
          textCapabilities
    qq <-
      withDb pool $
        ensureLegacyEndpoint
          PlatformQQ
          (NativeAccountId "9")
          (NativeConversationId "42")
          ConversationGroup
          42
          textCapabilities
    now <- getCurrentTime
    _ <- withDb pool (ingestEnvelope defaultIngestOptions (inbound qq.endpointId now "qq-after-matrix" "relay me"))
    claims <- claimStartedDeliveries pool "mirror-cutover" 10 30
    fmap (.endpointId) claims `shouldBe` [matrix.endpointId]

  it "deduplicates concurrent native events and atomically creates mirror delivery" $ do
    (qq, matrix) <- mirrorPair pool
    now <- getCurrentTime
    let envelope = inbound matrix.endpointId now "mx-event-1" "hello from Matrix"
    (left, right) <-
      concurrently
        (withDb pool (ingestEnvelope defaultIngestOptions envelope))
        (withDb pool (ingestEnvelope defaultIngestOptions envelope))

    let ids = resultId <$> [left, right]
    ids `shouldSatisfy` \case
      [a, b] -> a == b
      _ -> False
    [left, right] `shouldSatisfy` any isNew
    [left, right] `shouldSatisfy` any isDuplicate

    (messages, events, pendingDispatches, sourceConfirmed, mirrorPending) <-
      ledgerCounts pool matrix.endpointId qq.endpointId
    messages `shouldBe` 1
    events `shouldBe` 1
    pendingDispatches `shouldBe` 1
    sourceConfirmed `shouldBe` 1
    mirrorPending `shouldBe` 1

  it "mirrors what the transcript shows and keeps a command on its own endpoint" $ do
    (qq, matrix) <- mirrorPair pool
    now <- getCurrentTime
    _ <-
      withDb pool $
        ingestEnvelope
          (withTranscriptKind "command" defaultIngestOptions)
          (inbound matrix.endpointId now "mx-command" "!version")
    mirrored <- deliveriesFor pool qq.endpointId
    -- The other platform's members did not type it and cannot act on it, and
    -- an endpoint that echoes its own sends would read the copy back as a
    -- brand new message.
    mirrored `shouldBe` []
    _ <-
      withDb pool $
        ingestEnvelope
          defaultIngestOptions
          (inbound matrix.endpointId (addUTCTime 1 now) "mx-chat" "早")
    chatMirror <- deliveriesFor pool qq.endpointId
    map fst chatMirror `shouldBe` ["pending"]

  it "reads only max's own account as an echo when self events are echoes" $ do
    (_, matrix) <- mirrorPair pool
    now <- getCurrentTime
    -- The flag is an endpoint policy, not a claim about this event: a member
    -- speaking on an echoing endpoint is still a message.
    fromMember <-
      withDb pool $
        ingestEnvelope
          defaultIngestOptions {selfEventsAreEchoes = True}
          (inbound matrix.endpointId now "mx-member" "在的")
    fromMember `shouldSatisfy` isNew
    let selfSpoke =
          (inbound matrix.endpointId (addUTCTime 1 now) "mx-self" "[QQ · 好吧] !version")
            { senderNativeId = NativeUserId "@max:example.test"
            }
    withDb pool (ingestEnvelope defaultIngestOptions {selfEventsAreEchoes = True} selfSpoke)
      `shouldReturn` EchoUnmatched
    stored <- withConn pool $ \conn -> query conn "SELECT count(*) FROM messages" ()
    (stored :: [Only Int64]) `shouldBe` [Only 1]

  it "distinguishes a delivered mirror copy from a source event with the same native-id shape" $ do
    (qq, matrix) <- mirrorPair pool
    now <- getCurrentTime
    _ <- withDb pool (ingestEnvelope defaultIngestOptions (inbound qq.endpointId now "qq-source" "mirror me"))
    [claim] <- claimStartedDeliveries pool "imessage-reply-proof" 10 30
    withDb
      pool
      ( completeDelivery
          "imessage-reply-proof"
          claim.deliveryId
          claim.attemptCount
          []
          (DeliveryAccepted (Just (NativeEventId "imessage-copy")))
      )
      `shouldReturn` True

    withDb pool (nativeEventWasDeliveredTo matrix.endpointId (NativeEventId "imessage-copy"))
      `shouldReturn` True
    withDb pool (nativeEventWasDeliveredTo qq.endpointId (NativeEventId "qq-source"))
      `shouldReturn` False

  -- group_members was the OneBot member-list call, so a Matrix or iMessage
  -- conversation answered "成员列表获取失败" — the model was told nobody was
  -- in the room.  The ledger can answer anywhere, and it answers in
  -- principals, which is the only id ADR 004 lets the model act on.
  it "answers who is in the room on a platform with no member-list API" $ do
    (qq, matrix) <- mirrorPair pool
    now <- getCurrentTime
    _ <- withDb pool (ingestEnvelope defaultIngestOptions (inbound matrix.endpointId now "mx-1" "在"))
    _ <-
      withDb pool $
        ingestEnvelope
          defaultIngestOptions
          ((inbound qq.endpointId (addUTCTime 1 now) "qq-1" "也在") {senderNativeId = NativeUserId "2001"})
    roster <- withDb pool (conversationRoster 42)
    -- Both endpoints' accounts, plus max's own identity on each.
    map renderPlatform roster.crPlatforms `shouldMatchList` ["qq", "matrix"]
    map (.riNativeUserId) roster.crIdentities
      `shouldMatchList` ["9", "2001", "@max:example.test", "@alice:example.test"]
    -- Every entry names a person, and the native id is carried so a platform
    -- that can enumerate silent members has something to join on.
    roster.crIdentities `shouldSatisfy` all (\i -> i.riPrincipalId > PrincipalId 0)
    [i.riPrincipalId | i <- roster.crIdentities, i.riNativeUserId == "@alice:example.test"]
      `shouldSatisfy` ((== 1) . length)

  it "uses cursor CAS so stale pollers cannot skip a page" $ do
    (_, matrix) <- mirrorPair pool
    first <-
      withDb pool $
        advanceIngestCursorCAS
          matrix.platformAccountId
          "sync"
          Nothing
          (PlatformCursor (String "s1"))
          (Just "server-a")
    first `shouldBe` Just (CursorRecord (PlatformCursor (String "s1")) (Just "server-a") 0)
    stale <-
      withDb pool $
        advanceIngestCursorCAS matrix.platformAccountId "sync" Nothing (PlatformCursor (String "skip")) Nothing
    stale `shouldBe` Nothing
    advanced <-
      withDb pool $
        advanceIngestCursorCAS
          matrix.platformAccountId
          "sync"
          (Just 0)
          (PlatformCursor (String "s2"))
          (Just "server-a")
    advanced `shouldBe` Just (CursorRecord (PlatformCursor (String "s2")) (Just "server-a") 1)
    old <-
      withDb pool $
        advanceIngestCursorCAS matrix.platformAccountId "sync" (Just 0) (PlatformCursor (String "stale")) Nothing
    old `shouldBe` Nothing

  it "reports endpoint cursors and delivery ambiguity without joining counts twice" $ do
    (qq, matrix) <- mirrorPair pool
    now <- getCurrentTime
    _ <-
      withDb pool $
        advanceIngestCursorCAS matrix.platformAccountId "sync" Nothing (PlatformCursor (String "s1")) (Just "server-a")
    _ <- withDb pool (ingestEnvelope defaultIngestOptions (inbound matrix.endpointId now "mx-status" "status"))
    [claim] <- claimStartedDeliveries pool "worker-a" 10 30
    claim.endpointId `shouldBe` qq.endpointId
    _ <- withDb pool (completeDelivery "worker-a" claim.deliveryId claim.attemptCount [] (DeliveryUnknown "timeout" now))
    statuses <- withDb pool listPlatformStatus
    case [status | status <- statuses, status.endpointId == qq.endpointId] of
      [status] -> status.outcomeUnknownDeliveries `shouldBe` 1
      _ -> expectationFailure "missing QQ endpoint status"
    case [status | status <- statuses, status.endpointId == matrix.endpointId] of
      [status] -> do
        status.pendingDeliveries `shouldBe` 0
        show status.cursors `shouldContain` "s1"
      _ -> expectationFailure "missing Matrix endpoint status"

  it "leases each delivery once and rejects completion by a non-owner" $ do
    (qq, matrix) <- mirrorPair pool
    now <- getCurrentTime
    _ <- withDb pool (ingestEnvelope defaultIngestOptions (inbound matrix.endpointId now "mx-event-2" "deliver me"))
    claims <- claimStartedDeliveries pool "worker-a" 10 30
    claims `shouldSatisfy` \case
      [claim] -> claim.endpointId == qq.endpointId && claim.attemptCount == 1
      _ -> False
    again <- claimStartedDeliveries pool "worker-b" 10 30
    again `shouldBe` []
    claim <- case claims of
      [onlyClaim] -> pure onlyClaim
      _ -> expectationFailure "expected one leased delivery" >> fail "unreachable"
    stolen <-
      withDb pool $
        completeDelivery
          "worker-b"
          claim.deliveryId
          claim.attemptCount
          []
          (DeliveryConfirmedAs (Just (NativeEventId "qq-echo")))
    stolen `shouldBe` False
    completed <-
      withDb pool $
        completeDelivery
          "worker-a"
          claim.deliveryId
          claim.attemptCount
          []
          (DeliveryConfirmedAs (Just (NativeEventId "qq-echo")))
    completed `shouldBe` True

  it "re-offers an expired delivery reservation without counting an attempt" $ do
    (_, matrix) <- mirrorPair pool
    now <- getCurrentTime
    _ <- withDb pool (ingestEnvelope defaultIngestOptions (inbound matrix.endpointId now "mx-reserved" "not started yet"))
    [reserved] <- withDb pool (claimDeliveries "worker-gone" 10 30)
    reserved.attemptCount `shouldBe` 1
    _ <- withConn pool $ \conn ->
      execute
        conn
        "UPDATE message_deliveries SET lease_expires_at = now() - interval '1 second' WHERE delivery_id = ?"
        (Only reserved.deliveryId.unDeliveryId)

    [reclaimed] <- withDb pool (claimDeliveries "worker-next" 10 30)
    reclaimed.deliveryId `shouldBe` reserved.deliveryId
    reclaimed.attemptCount `shouldBe` 1
    withDb pool (startDelivery "worker-next" reclaimed.deliveryId reclaimed.attemptCount 30)
      `shouldReturn` True

  -- Delivery runs one lane per platform so a wedged edge cannot pace the
  -- others: an unreachable iMessage bridge timing out at 90s per attempt used
  -- to sit in a shared batch and put that delay in front of every QQ reply
  -- behind it.  That only works if the lanes partition the queue, so pin both
  -- halves of the partition here.
  it "gives each platform lane its own endpoints and nothing else" $ do
    (qq, matrix) <- mirrorPair pool
    now <- getCurrentTime
    -- One message each way, so both platforms have a delivery outstanding at
    -- the same time — the case a single shared worker used to serialise.
    _ <- withDb pool (ingestEnvelope defaultIngestOptions (inbound matrix.endpointId now "mx-lane" "from matrix"))
    _ <- withDb pool (ingestEnvelope defaultIngestOptions (inbound qq.endpointId (addUTCTime 1 now) "qq-lane" "from qq"))

    qqLane <- withDb pool (claimDeliveriesForLane "lane-qq" (LanePlatform PlatformQQ) 10 30)
    fmap (.platform) qqLane `shouldBe` [PlatformQQ]
    fmap (.endpointId) qqLane `shouldBe` [qq.endpointId]

    -- Claimed while the QQ row is already reserved by the lane above: the
    -- Matrix lane must not be waiting on it.
    matrixLane <- withDb pool (claimDeliveriesForLane "lane-matrix" (LanePlatform PlatformMatrix) 10 30)
    fmap (.platform) matrixLane `shouldBe` [PlatformMatrix]
    fmap (.endpointId) matrixLane `shouldBe` [matrix.endpointId]

  it "leaves the platform lanes' complement to the unrouted lane" $ do
    (qq, matrix) <- mirrorPair pool
    now <- getCurrentTime
    _ <- withDb pool (ingestEnvelope defaultIngestOptions (inbound matrix.endpointId now "mx-unrouted" "from matrix"))
    _ <- withDb pool (ingestEnvelope defaultIngestOptions (inbound qq.endpointId (addUTCTime 1 now) "qq-unrouted" "from qq"))

    -- A process holding transports for both platforms has no residual work,
    -- so the extra lane costs a poll and claims nothing.
    covered <- withDb pool (claimDeliveriesForLane "lane-none" (LaneUnrouted [PlatformQQ, PlatformMatrix]) 10 30)
    fmap (.platform) covered `shouldBe` []

    -- Drop QQ from the served set, as a process with no QQ transport has it:
    -- the QQ delivery is then exactly the unrouted lane's job.  Without that
    -- lane nobody claims it and it stays pending forever instead of failing.
    unrouted <- withDb pool (claimDeliveriesForLane "lane-unrouted" (LaneUnrouted [PlatformMatrix]) 10 30)
    fmap (.platform) unrouted `shouldBe` [PlatformQQ]
    fmap (.endpointId) unrouted `shouldBe` [qq.endpointId]

  it "quarantines an expired sending lease without retrying it or blocking the endpoint" $ do
    (qq, matrix) <- mirrorPair pool
    now <- getCurrentTime
    _ <- withDb pool (ingestEnvelope defaultIngestOptions (inbound matrix.endpointId now "mx-expired-1" "maybe sent"))
    _ <- withDb pool (ingestEnvelope defaultIngestOptions (inbound matrix.endpointId (addUTCTime 1 now) "mx-expired-2" "send after it"))
    [abandoned] <- claimStartedDeliveries pool "worker-gone" 10 30
    abandoned.endpointId `shouldBe` qq.endpointId
    _ <- withConn pool $ \conn ->
      execute
        conn
        "UPDATE message_deliveries SET lease_expires_at = now() - interval '1 second' WHERE delivery_id = ?"
        (Only abandoned.deliveryId.unDeliveryId)

    [next] <- claimStartedDeliveries pool "worker-next" 10 30
    next.endpointId `shouldBe` qq.endpointId
    next.body `shouldBe` Body [NText "send after it"]
    next.deliveryId `shouldNotBe` abandoned.deliveryId
    withDb
      pool
      (completeDelivery "worker-gone" abandoned.deliveryId abandoned.attemptCount [] (DeliveryConfirmedAs (Just (NativeEventId "late-receipt"))))
      `shouldReturn` False

    rows <- withConn pool $ \conn ->
      query
        conn
        "SELECT status, lease_owner, lease_expires_at, last_error FROM message_deliveries WHERE delivery_id = ?"
        (Only abandoned.deliveryId.unDeliveryId)
    (rows :: [(Text, Maybe Text, Maybe UTCTime, Maybe Text)])
      `shouldSatisfy` \case
        [("outcome_unknown", Nothing, Nothing, Just err)] -> "lease expired" `T.isInfixOf` err
        _ -> False

  -- The retry budget in Max.Platform.Delivery converts an exhausted retryable
  -- attempt into a permanent failure precisely so the endpoint's ordered lane
  -- stops waiting on a copy that can never land.  That only works if a terminal
  -- row leaves the blocking set.
  it "releases the ordered lane once a poisoned copy permanently fails" $ do
    (qq, matrix) <- mirrorPair pool
    now <- getCurrentTime
    _ <- withDb pool (ingestEnvelope defaultIngestOptions (inbound matrix.endpointId now "mx-poison" "risk controlled"))
    _ <- withDb pool (ingestEnvelope defaultIngestOptions (inbound matrix.endpointId (addUTCTime 1 now) "mx-after" "queued behind it"))
    [poisoned] <- claimStartedDeliveries pool "worker-a" 10 30
    poisoned.endpointId `shouldBe` qq.endpointId
    -- Its successor stays blocked while the head is retryable.
    withDb pool (completeDelivery "worker-a" poisoned.deliveryId poisoned.attemptCount [] (DeliveryRetry "retcode 1200" now))
      `shouldReturn` True
    [retried] <- claimStartedDeliveries pool "worker-b" 10 30
    retried.deliveryId `shouldBe` poisoned.deliveryId
    withDb
      pool
      (completeDelivery "worker-b" retried.deliveryId retried.attemptCount [] (DeliveryPermanentlyFailed "retry budget exhausted after 16 attempts: retcode 1200"))
      `shouldReturn` True
    rows <- withConn pool $ \conn ->
      query
        conn
        "SELECT status FROM message_deliveries WHERE delivery_id = ?"
        (Only retried.deliveryId.unDeliveryId)
    (rows :: [Only Text]) `shouldBe` [Only "permanent_failure"]
    released <- claimStartedDeliveries pool "worker-c" 10 30
    fmap (.canonicalMessageId) released `shouldSatisfy` ((== 1) . length)
    released `shouldSatisfy` all ((/= poisoned.deliveryId) . (.deliveryId))

  it "reports deterministic poison separately from deliberate suppression" $ do
    (qq, matrix) <- mirrorPair pool
    now <- getCurrentTime
    _ <- withDb pool (ingestEnvelope defaultIngestOptions (inbound matrix.endpointId now "mx-permanent" "poison"))
    [poisoned] <- claimStartedDeliveries pool "worker-a" 10 30
    withDb
      pool
      (completeDelivery "worker-a" poisoned.deliveryId poisoned.attemptCount [] (DeliveryPermanentlyFailed "invalid target"))
      `shouldReturn` True
    _ <- withDb pool (ingestEnvelope defaultIngestOptions (inbound matrix.endpointId (addUTCTime 1 now) "mx-suppressed" "policy"))
    [suppressed] <- claimStartedDeliveries pool "worker-b" 10 30
    withDb
      pool
      (completeDelivery "worker-b" suppressed.deliveryId suppressed.attemptCount [] (DeliverySuppressedAs "reaction unsupported"))
      `shouldReturn` True
    rows <- withConn pool $ \conn ->
      query
        conn
        "SELECT status, count(*) FROM message_deliveries WHERE endpoint_id = ? GROUP BY status ORDER BY status"
        (Only qq.endpointId.unEndpointId)
    (rows :: [(Text, Int64)]) `shouldBe` [("permanent_failure", 1), ("suppressed", 1)]
    statuses <- withDb pool listPlatformStatus
    case [status | status <- statuses, status.endpointId == qq.endpointId] of
      [status] -> do
        status.permanentFailureDeliveries `shouldBe` 1
        status.suppressedDeliveries `shouldBe` 1
      _ -> expectationFailure "missing QQ endpoint status"

  it "persists the shared lowerer's degradation audit on completion" $ do
    (qq, matrix) <- mirrorPair pool
    now <- getCurrentTime
    _ <- withDb pool (ingestEnvelope defaultIngestOptions (inbound matrix.endpointId now "mx-lower-notes" "hello"))
    [claim] <- claimStartedDeliveries pool "worker-a" 10 30
    let notes = [LowerNote "mention" NoteFolded (Just "no identity on endpoint")]
    withDb pool (completeDelivery "worker-a" claim.deliveryId claim.attemptCount notes (DeliveryConfirmedAs Nothing))
      `shouldReturn` True
    rows <- withConn pool $ \conn ->
      query
        conn
        "SELECT lower_notes FROM message_deliveries WHERE delivery_id = ?"
        (Only claim.deliveryId.unDeliveryId)
    (rows :: [Only Value]) `shouldBe` [Only (toJSON notes)]
    claim.endpointId `shouldBe` qq.endpointId

  it "discards a provider receipt already owned by another delivery" $ do
    (qq, matrix) <- mirrorPair pool
    now <- getCurrentTime
    _ <- withDb pool (ingestEnvelope defaultIngestOptions (inbound matrix.endpointId now "mx-reused-1" "first"))
    _ <- withDb pool (ingestEnvelope defaultIngestOptions (inbound matrix.endpointId now "mx-reused-2" "second"))
    firstClaims <- claimStartedDeliveries pool "worker-a" 10 30
    firstClaims `shouldSatisfy` \case
      [claim] -> claim.endpointId == qq.endpointId && claim.body == Body [NText "first"]
      _ -> False
    case firstClaims of
      [firstClaim] -> do
        withDb pool (completeDelivery "worker-a" firstClaim.deliveryId firstClaim.attemptCount [] (DeliveryAccepted (Just (NativeEventId "reused-native"))))
          `shouldReturn` True
        secondClaims <- claimStartedDeliveries pool "worker-a" 10 30
        secondClaims `shouldSatisfy` \case
          [claim] -> claim.endpointId == qq.endpointId && claim.body == Body [NText "second"]
          _ -> False
        secondClaim <- case secondClaims of
          [claim] -> pure claim
          _ -> expectationFailure "expected the second ordered delivery" >> fail "unreachable"
        withDb pool (completeDelivery "worker-a" secondClaim.deliveryId secondClaim.attemptCount [] (DeliveryAccepted (Just (NativeEventId "reused-native"))))
          `shouldReturn` True
        deliveries <- withConn pool $ \conn ->
          query
            conn
            "SELECT status, native_event_id FROM message_deliveries WHERE endpoint_id = ? ORDER BY delivery_id"
            (Only qq.endpointId.unEndpointId)
        (deliveries :: [(Text, Maybe Text)])
          `shouldBe` [("accepted_unconfirmed", Just "reused-native"), ("accepted_unconfirmed", Nothing)]
      _ -> expectationFailure "expected the first ordered delivery"

  it "never automatically retries an outcome-unknown non-idempotent delivery" $ do
    (qq, matrix) <- mirrorPair pool
    now <- getCurrentTime
    _ <- withDb pool (ingestEnvelope defaultIngestOptions (inbound matrix.endpointId now "mx-unknown" "maybe sent"))
    [claim] <- claimStartedDeliveries pool "worker-a" 10 30
    claim.endpointId `shouldBe` qq.endpointId
    unknown <-
      withDb pool $
        completeDelivery "worker-a" claim.deliveryId claim.attemptCount [] (DeliveryUnknown "timeout after write" (addUTCTime (-1) now))
    unknown `shouldBe` True
    claimStartedDeliveries pool "worker-b" 10 30 `shouldReturn` []

  it "requeues an accepted send only after explicit provider failure evidence" $ do
    (qq, matrix) <- mirrorPair pool
    now <- getCurrentTime
    _ <- withDb pool (ingestEnvelope defaultIngestOptions (inbound qq.endpointId now "qq-reconcile" "status me"))
    [claim] <- claimStartedDeliveries pool "worker-a" 10 30
    claim.endpointId `shouldBe` matrix.endpointId
    accepted <-
      withDb pool $
        completeDelivery "worker-a" claim.deliveryId claim.attemptCount [] (DeliveryAccepted (Just (NativeEventId "native-out")))
    accepted `shouldBe` True
    claimStartedDeliveries pool "worker-b" 10 30 `shouldReturn` []
    unconfirmed <- withDb pool (listUnconfirmedDeliveries PlatformMatrix 10)
    fmap (.deliveryId) unconfirmed `shouldBe` [claim.deliveryId]
    withDb pool (confirmUnconfirmedDelivery claim.deliveryId (NativeEventId "wrong")) `shouldReturn` False
    withDb pool (retryUnconfirmedDelivery claim.deliveryId (NativeEventId "native-out") "provider failed")
      `shouldReturn` True
    retried <- claimStartedDeliveries pool "worker-b" 10 30
    fmap (.deliveryId) retried `shouldBe` [claim.deliveryId]

  it "confirms an accepted send through a status reconciliation CAS" $ do
    (qq, matrix) <- mirrorPair pool
    now <- getCurrentTime
    _ <- withDb pool (ingestEnvelope defaultIngestOptions (inbound qq.endpointId now "qq-confirm" "confirm me"))
    [claim] <- claimStartedDeliveries pool "worker-a" 10 30
    claim.endpointId `shouldBe` matrix.endpointId
    _ <- withDb pool (completeDelivery "worker-a" claim.deliveryId claim.attemptCount [] (DeliveryAccepted (Just (NativeEventId "native-confirm"))))
    withDb pool (confirmUnconfirmedDelivery claim.deliveryId (NativeEventId "native-confirm"))
      `shouldReturn` True
    withDb pool (listUnconfirmedDeliveries PlatformMatrix 10) `shouldReturn` []

  it "leases dispatch eligibility once and recovers only after its lease" $ do
    (_, matrix) <- mirrorPair pool
    now <- getCurrentTime
    result <- withDb pool (ingestEnvelope defaultIngestOptions (inbound matrix.endpointId now "mx-dispatch" "dispatch me"))
    let cid = resultId result
    first <- claimStartedDispatch pool "runtime-a" cid 30
    fmap (.canonicalMessageId) first `shouldBe` Just cid
    claimStartedDispatch pool "runtime-b" cid 30 `shouldReturn` Nothing
    case first of
      Nothing -> expectationFailure "expected dispatch claim"
      Just claim -> do
        completed <- withDb pool (completeDispatch "runtime-a" cid claim.attemptCount DispatchCompleted)
        completed `shouldBe` True
        claimStartedDispatch pool "runtime-b" cid 30 `shouldReturn` Nothing

  it "re-offers an expired dispatch reservation without counting an attempt" $ do
    (_, matrix) <- mirrorPair pool
    now <- getCurrentTime
    result <- withDb pool (ingestEnvelope defaultIngestOptions (inbound matrix.endpointId now "mx-dispatch-reserved" "not started yet"))
    let cid = resultId result
    reserved <- withDb pool (claimDispatch "runtime-gone" cid 30)
    fmap (.attemptCount) reserved `shouldBe` Just 1
    _ <- withConn pool $ \conn ->
      execute
        conn
        "UPDATE message_dispatches SET lease_expires_at = now() - interval '1 minute' \
        \ WHERE canonical_message_id = ?"
        (Only cid.unCanonicalMessageId)

    reclaimed <- withDb pool (claimDispatch "runtime-next" cid 30)
    fmap (.canonicalMessageId) reclaimed `shouldBe` Just cid
    fmap (.attemptCount) reclaimed `shouldBe` Just 1
    forM_ reclaimed $ \claim ->
      withDb pool (startDispatch "runtime-next" cid claim.attemptCount 30)
        `shouldReturn` True

  -- The claim query only ever selects 'pending' and 'failed', so its lease
  -- expiry test cannot reach a row abandoned in 'claimed' — that row is
  -- outside the candidate set however long ago the lease ran out.  Nothing
  -- else looked at it either, which is how one sat stranded in production for
  -- three days.  Quarantine, not retry: the abandoned turn may already have
  -- replied, and a duplicate reply cannot be withdrawn.
  it "quarantines an abandoned dispatch claim instead of stranding or retrying it" $ do
    (_, matrix) <- mirrorPair pool
    now <- getCurrentTime
    result <- withDb pool (ingestEnvelope defaultIngestOptions (inbound matrix.endpointId now "mx-abandoned" "answer me"))
    let cid = resultId result
    claimed <- claimStartedDispatch pool "runtime-doomed" cid 30
    fmap (.canonicalMessageId) claimed `shouldBe` Just cid

    -- The worker dies here: the lease lapses with the row still 'claimed'.
    _ <- withConn pool $ \conn ->
      execute
        conn
        "UPDATE message_dispatches SET lease_expires_at = now() - interval '1 minute' \
        \ WHERE canonical_message_id = ?"
        (Only cid.unCanonicalMessageId)

    -- Any later claim attempt sweeps it, and does not hand it back out.
    claimStartedDispatch pool "runtime-next" cid 30 `shouldReturn` Nothing
    status <- withConn pool $ \conn ->
      query
        conn
        "SELECT status, lease_owner IS NULL, last_error IS NOT NULL \
        \ FROM message_dispatches WHERE canonical_message_id = ?"
        (Only cid.unCanonicalMessageId)
    status `shouldBe` [("outcome_unknown" :: Text, True, True)]

  -- The other half of that sweep.  Issue #17.D handed the row to the turn, so
  -- the lease stopped measuring "the claim loop is between two statements" and
  -- started measuring "a turn is running" — and 3.6% of production turns run
  -- longer than the entire lease.  Without renewal the sweep above would fire
  -- on healthy turns, quarantine their rows, and make the settle at the end of
  -- the turn match nothing: the message answered, the row saying otherwise.
  it "keeps a claim a running turn is still holding, and the sweep passes it by" $ do
    (_, matrix) <- mirrorPair pool
    now <- getCurrentTime
    result <- withDb pool (ingestEnvelope defaultIngestOptions (inbound matrix.endpointId now "mx-longturn" "this will take a while"))
    let cid = resultId result
    claimed <- claimStartedDispatch pool "runtime-slow" cid 30
    fmap (.canonicalMessageId) claimed `shouldBe` Just cid
    attempt <- claimAttempt claimed

    -- The turn outlives its lease.  Renewal deliberately does not test the
    -- expiry it is replacing: a heartbeat that arrives a second late should
    -- still save the row, because the alternative is losing a turn that is
    -- demonstrably alive — it just wrote to this row.
    _ <- withConn pool $ \conn ->
      execute
        conn
        "UPDATE message_dispatches SET lease_expires_at = now() - interval '1 minute' \
        \ WHERE canonical_message_id = ?"
        (Only cid.unCanonicalMessageId)
    withDb pool (renewDispatchLease "runtime-slow" cid attempt 30) `shouldReturn` True

    claimStartedDispatch pool "runtime-other" cid 30 `shouldReturn` Nothing
    held <- withConn pool $ \conn ->
      query
        conn
        "SELECT status, lease_owner, COALESCE(lease_expires_at > now(), false) \
        \ FROM message_dispatches WHERE canonical_message_id = ?"
        (Only cid.unCanonicalMessageId)
    (held :: [(Text, Maybe Text, Bool)]) `shouldBe` [("claimed", Just "runtime-slow", True)]

    -- And the turn's own ending still lands, which is the point of holding it.
    withDb pool (completeDispatch "runtime-slow" cid attempt DispatchCompleted) `shouldReturn` True
    -- Settled is settled: a renewal racing the epilogue finds nothing to hold
    -- and says so rather than resurrecting the lease on a finished row.
    withDb pool (renewDispatchLease "runtime-slow" cid attempt 30) `shouldReturn` False

  -- Issue #17.C.  A message that arrives while its conversation is busy used
  -- to be folded into whatever turn happened to be running — production had
  -- one person's unrelated question absorbed into a stranger's turn and never
  -- separately answered.  It now waits, which needs a state that is neither
  -- "answered" nor "failed".
  it "defers a dispatch instead of completing it, and releases it per conversation" $ do
    (_, matrix) <- mirrorPair pool
    now <- getCurrentTime
    result <- withDb pool (ingestEnvelope defaultIngestOptions (inbound matrix.endpointId now "mx-defer" "answer me later"))
    let cid = resultId result
    claimed <- claimStartedDispatch pool "runtime-busy" cid 30
    fmap (.canonicalMessageId) claimed `shouldBe` Just cid
    attempt <- claimAttempt claimed
    withDb pool (completeDispatch "runtime-busy" cid attempt (DispatchDeferred (addUTCTime 30 now)))
      `shouldReturn` True
    -- Nothing went wrong and nothing was answered: an operator reading either
    -- the failed rows or the completed ones must not find this one in them.
    row <- withConn pool $ \conn ->
      query
        conn
        "SELECT status, completed_at IS NULL, last_error IS NULL \
        \ FROM message_dispatches WHERE canonical_message_id = ?"
        (Only cid.unCanonicalMessageId)
    (row :: [(Text, Bool, Bool)]) `shouldBe` [("deferred", True, True)]
    -- The dispatch epilogue writes DispatchCompleted unconditionally on every
    -- exit.  That it cannot undo the deferral is the whole ordering argument:
    -- the status guard only matches a row still claimed.
    withDb pool (completeDispatch "runtime-busy" cid attempt DispatchCompleted) `shouldReturn` False
    gid <- withConn pool $ \conn ->
      query
        conn
        "SELECT group_id FROM messages WHERE canonical_message_id = ?"
        (Only cid.unCanonicalMessageId)
    case (gid :: [Only Int64]) of
      [Only raw] -> do
        -- Scoped to the conversation whose turn just ended, not to every
        -- conversation that happens to be waiting.
        withDb pool (releaseDeferredDispatches (raw + 1)) `shouldReturn` 0
        withDb pool (releaseDeferredDispatches raw) `shouldReturn` 1
        -- Same worker: a worker identity is per process, so the row this
        -- process deferred comes back to the same name it left under.
        reclaimed <- claimStartedDispatch pool "runtime-busy" cid 30
        fmap (.canonicalMessageId) reclaimed `shouldBe` Just cid
        retried <- claimAttempt reclaimed
        retried `shouldNotBe` attempt

        -- And here is the window the fence exists for.  The deferring turn's
        -- epilogue is still unwinding, and by the time it reaches its
        -- unconditional DispatchCompleted the row is claimed again, by the
        -- same worker, for a turn that has not answered anything yet.  Owner
        -- and status both match; only the attempt does not.
        withDb pool (completeDispatch "runtime-busy" cid attempt DispatchCompleted)
          `shouldReturn` False
        stillOurs <- withConn pool $ \conn ->
          query
            conn
            "SELECT status FROM message_dispatches WHERE canonical_message_id = ?"
            (Only cid.unCanonicalMessageId)
        (stillOurs :: [Only Text]) `shouldBe` [Only "claimed"]
        -- The live claim settles it, as it always could.
        withDb pool (completeDispatch "runtime-busy" cid retried DispatchCompleted)
          `shouldReturn` True
      other -> expectationFailure ("expected one group id, got " <> show other)

  -- The release is the precise wakeup, not the only one.  A row whose
  -- releasing turn died has to come back through the ordinary scan or a busy
  -- conversation could strand a question permanently.
  it "hands back a deferred dispatch nobody released once its wait is over" $ do
    (_, matrix) <- mirrorPair pool
    now <- getCurrentTime
    result <- withDb pool (ingestEnvelope defaultIngestOptions (inbound matrix.endpointId now "mx-stranded" "still waiting"))
    let cid = resultId result
    stale <- claimStartedDispatch pool "runtime-gone" cid 30
    staleAttempt <- claimAttempt stale
    withDb pool (completeDispatch "runtime-gone" cid staleAttempt (DispatchDeferred (addUTCTime (-1) now)))
      `shouldReturn` True
    reclaimed <- claimStartedDispatch pool "runtime-next" cid 30
    fmap (.canonicalMessageId) reclaimed `shouldBe` Just cid

  it "maps every wire part echo and reply without prematurely settling the parent" $ do
    (qq, matrix) <- mirrorPair pool
    now <- getCurrentTime
    original <- withDb pool (ingestEnvelope defaultIngestOptions (inbound matrix.endpointId now "split-original" "onetwo"))
    [claim] <- claimStartedDeliveries pool "parts" 10 120
    withDb pool (planDeliveryParts "parts" claim ["one", "two"]) `shouldReturn` True
    withDb pool (beginDeliveryPart "parts" claim NonIdempotentParts 0) `shouldReturn` PartSend
    withDb pool (finishDeliveryPart "parts" claim 0 (AttemptAccepted (Just (NativeEventId "part-one")))) `shouldReturn` True
    let echo native text = (inbound qq.endpointId now native text) {senderNativeId = NativeUserId "9"}
    withDb pool (ingestEnvelope defaultIngestOptions (echo "part-one" "one")) `shouldReturn` DeliveryEcho (resultId original)
    withDb pool (renewDelivery "parts" claim 120) `shouldReturn` True
    withDb pool (beginDeliveryPart "parts" claim NonIdempotentParts 1) `shouldReturn` PartSend
    withDb pool (finishDeliveryPart "parts" claim 1 (AttemptAccepted (Just (NativeEventId "part-two")))) `shouldReturn` True
    -- A reply may arrive before the platform echoes the part.
    reply <- withDb pool (ingestEnvelope defaultIngestOptions ((inbound qq.endpointId now "reply-second" "question") {relations = [ReplyTo (NativeEventId "part-two")]}))
    linked <- withConn pool $ \conn -> query conn "SELECT target_canonical_message_id FROM message_relations WHERE canonical_message_id=? AND relation_kind='reply'" (Only (resultId reply).unCanonicalMessageId)
    (linked :: [Only Int64]) `shouldBe` [Only (resultId original).unCanonicalMessageId]
    withDb pool (completeDelivery "parts" claim.deliveryId claim.attemptCount [] (DeliveryAccepted (Just (NativeEventId "part-one")))) `shouldReturn` True
    withDb pool (ingestEnvelope defaultIngestOptions (echo "part-two" "two")) `shouldReturn` DeliveryEcho (resultId original)
    states <- withConn pool $ \conn -> query conn "SELECT status FROM message_deliveries WHERE delivery_id=?" (Only claim.deliveryId.unDeliveryId)
    (states :: [Only Text]) `shouldBe` [Only "confirmed"]
    followup <- withDb pool (enqueueOutbound (OutboundDraft 42 "chat" Nothing (Body [NText "followup"]) (Just (resultId original).unCanonicalMessageId) Nothing Nothing))
    _ <- withConn pool $ \conn -> execute conn "UPDATE message_relations SET target_native_event_id='part-two' WHERE canonical_message_id=? AND relation_kind='reply'" (Only followup.canonicalMessageId.unCanonicalMessageId)
    -- Make a different chunk the newest echo: explicit part identity wins.
    _ <- withConn pool $ \conn -> execute conn "UPDATE platform_events SET occurred_at=now()+interval '1 minute' WHERE native_event_id='part-one'" ()
    Just quotedPart <- withDb pool (claimDelivery "quote-part" followup.primaryDeliveryId 120)
    (quotedPart.replyContext >>= (.nativeId)) `shouldBe` Just (NativeEventId "part-two")

  it "reconciles provider status per part and retries only an explicitly failed part" $ do
    (_, matrix) <- mirrorPair pool
    now <- getCurrentTime
    _ <- withDb pool (ingestEnvelope defaultIngestOptions (inbound matrix.endpointId now "status-original" "onetwo"))
    [claim] <- claimStartedDeliveries pool "parts" 10 120
    _ <- withDb pool (planDeliveryParts "parts" claim ["one", "two"])
    forM_ [(0, "one"), (1, "two")] $ \(index, native) -> do
      _ <- withDb pool (beginDeliveryPart "parts" claim NonIdempotentParts index)
      _ <- withDb pool (finishDeliveryPart "parts" claim index (AttemptAccepted (Just (NativeEventId native))))
      pure ()
    _ <- withDb pool (completeDelivery "parts" claim.deliveryId claim.attemptCount [] (DeliveryAccepted (Just (NativeEventId "one"))))
    unconfirmedParts <- withDb pool (listUnconfirmedDeliveries PlatformQQ 10)
    length unconfirmedParts `shouldBe` 2
    withDb pool (confirmUnconfirmedDelivery claim.deliveryId (NativeEventId "one")) `shouldReturn` True
    remaining <- withDb pool (listUnconfirmedDeliveries PlatformQQ 10)
    map (.nativeEventId) remaining `shouldBe` [NativeEventId "two"]
    withDb pool (retryUnconfirmedDelivery claim.deliveryId (NativeEventId "two") "provider explicitly failed") `shouldReturn` True
    [retry] <- claimStartedDeliveries pool "retry" 10 120
    withDb pool (beginDeliveryPart "retry" retry NonIdempotentParts 0)
      `shouldReturn` PartRecorded (AttemptConfirmed (Just (NativeEventId "one")))
    withDb pool (beginDeliveryPart "retry" retry NonIdempotentParts 1) `shouldReturn` PartSend

  it "resumes only the remaining wire part and rejects a changed retry plan" $ do
    (_, matrix) <- mirrorPair pool
    now <- getCurrentTime
    _ <- withDb pool (ingestEnvelope defaultIngestOptions (inbound matrix.endpointId now "retry-original" "onetwo"))
    [claim] <- claimStartedDeliveries pool "parts" 10 120
    withDb pool (planDeliveryParts "parts" claim ["one", "two"]) `shouldReturn` True
    _ <- withDb pool (beginDeliveryPart "parts" claim IdempotentParts 0)
    _ <- withDb pool (finishDeliveryPart "parts" claim 0 (AttemptConfirmed (Just (NativeEventId "one"))))
    _ <- withDb pool (beginDeliveryPart "parts" claim IdempotentParts 1)
    _ <- withDb pool (finishDeliveryPart "parts" claim 1 (AttemptRetryable "503"))
    _ <- withDb pool (completeDelivery "parts" claim.deliveryId claim.attemptCount [] (DeliveryRetry "503" now))
    [retry] <- claimStartedDeliveries pool "parts-next" 10 120
    withDb pool (planDeliveryParts "parts-next" retry ["changed"]) `shouldReturn` False
    withDb pool (planDeliveryParts "parts-next" retry ["one", "two"]) `shouldReturn` True
    withDb pool (beginDeliveryPart "parts-next" retry IdempotentParts 0)
      `shouldReturn` PartRecorded (AttemptConfirmed (Just (NativeEventId "one")))
    withDb pool (beginDeliveryPart "parts-next" retry IdempotentParts 1) `shouldReturn` PartSend
    withDb pool (finishDeliveryPart "parts" claim 1 (AttemptConfirmed (Just (NativeEventId "stale")))) `shouldReturn` False

  it "retries a Matrix second-part 503 with the same transaction and without resending the first" $ do
    (qq, _) <- mirrorPair pool
    now <- getCurrentTime
    _ <- withDb pool (ingestEnvelope defaultIngestOptions (inbound qq.endpointId now "matrix-retry" "onetwo"))
    [claim] <- claimStartedDeliveries pool "matrix-parts" 10 120
    responses <- newIORef [(200 :: Int, "{\"event_id\":\"$one\"}"), (503, "{\"errcode\":\"M_UNKNOWN\"}"), (200, "{\"event_id\":\"$two\"}")]
    count <- newIORef (0 :: Int)
    manager <-
      HTTP.newManager
        HTTP.defaultManagerSettings
          { HTTP.managerRawConnection = pure $ \_ _ _ -> do
              modifyIORef' count (+ 1)
              (status, payload) <- atomicModifyIORef' responses $ \case
                [] -> ([], (500, "{}"))
                value : rest -> (rest, value)
              wire <- newIORef ["HTTP/1.1 " <> BS.pack (show status) <> " status\r\nContent-Length: " <> BS.pack (show (BS.length payload)) <> "\r\nConnection: close\r\n\r\n" <> payload]
              HTTP.makeConnection
                (atomicModifyIORef' wire (\case [] -> ([], BS.empty); x : xs -> (xs, x)))
                (const (pure ()))
                (pure ()),
            HTTP.managerRetryableException = const False
          }
    let transport =
          matrixDeliveryTransport
            (httpRuntimeFromManagers manager manager manager)
            (MatrixConfig "http://matrix.test" "test-only" "@max:test" "!room:test" Nothing 1000)
        journal worker current =
          PartJournal
            { plan = withDb pool . planDeliveryParts worker current,
              begin = \safety index -> withDb pool (beginDeliveryPart worker current safety index),
              finish = \index result -> withDb pool (finishDeliveryPart worker current index result)
            }
        operation = DeliverMessage (LoweredMessage Nothing [[NText "one"], [NText "two"]] [])
    first <- transport.deliver (journal "matrix-parts" claim) claim operation
    case first of
      AttemptRetryable _ -> pure ()
      other -> expectationFailure (show other)
    _ <- withDb pool (completeDelivery "matrix-parts" claim.deliveryId claim.attemptCount [] (DeliveryRetry "503" now))
    [retry] <- claimStartedDeliveries pool "matrix-next" 10 120
    transport.deliver (journal "matrix-next" retry) retry operation
      `shouldReturn` AttemptConfirmed (Just (NativeEventId "$one"))
    readIORef count `shouldReturn` 3
    keys <- withConn pool $ \conn -> query conn "SELECT idempotency_key,status FROM message_delivery_parts WHERE delivery_id=? ORDER BY part_index" (Only claim.deliveryId.unDeliveryId)
    (keys :: [(Text, Text)]) `shouldBe` [(claim.idempotencyKey <> "-0", "confirmed"), (claim.idempotencyKey <> "-1", "confirmed")]

  it "emits a canonical QQ file through the part journal and removes edge staging" $ do
    (_, matrix) <- mirrorPair pool
    now <- getCurrentTime
    _ <- withDb pool (ingestEnvelope defaultIngestOptions (inbound matrix.endpointId now "file-original" "file"))
    [claim] <- claimStartedDeliveries pool "file-worker" 10 120
    staged <- newIORef []
    let backend = PlatformBackend "qq" "fake" (const (pure (Right ()))) $ \action _ -> case action of
          UploadGroupFile _ path name -> do
            name `shouldBe` "report.csv"
            let host = "var/outbox/" <> T.unpack (T.drop (T.length ("/data/outbox/" :: Text)) path)
            BS.readFile host `shouldReturn` "a,b\n1,2"
            modifyIORef' staged (host :)
            pure (Right (Response "ok" 0 Null ""))
          other -> expectationFailure (show other) >> pure (Left "unexpected action")
        journal =
          PartJournal
            { plan = withDb pool . planDeliveryParts "file-worker" claim,
              begin = \safety index -> withDb pool (beginDeliveryPart "file-worker" claim safety index),
              finish = \index result -> withDb pool (finishDeliveryPart "file-worker" claim index result)
            }
    manager <- HTTP.newManager HTTP.defaultManagerSettings
    let transport = oneBotDeliveryTransport (httpRuntimeFromManagers manager manager manager) PlatformQQ backend
        meta = MediaMeta MFile Nothing (Just 7) (Just "report.csv") Nothing Nothing
    transport.deliver journal claim (DeliverMessage (LoweredMessage Nothing [[NMedia (ResolvedBytes "a,b\n1,2") meta]] []))
      `shouldReturn` AttemptAccepted Nothing
    paths <- readIORef staged
    length paths `shouldBe` 1
    mapM doesFileExist paths `shouldReturn` [False]

  it "stops parts after lease loss and fences a late completion" $ do
    (_, matrix) <- mirrorPair pool
    now <- getCurrentTime
    _ <- withDb pool (ingestEnvelope defaultIngestOptions (inbound matrix.endpointId now "expired-original" "body"))
    [claim] <- claimStartedDeliveries pool "parts" 10 120
    withDb pool (planDeliveryParts "parts" claim ["body"]) `shouldReturn` True
    _ <- withConn pool $ \conn -> execute conn "UPDATE message_deliveries SET lease_expires_at=now()-interval '1 second' WHERE delivery_id=?" (Only claim.deliveryId.unDeliveryId)
    withDb pool (renewDelivery "parts" claim 120) `shouldReturn` False
    withDb pool (completeDelivery "parts" claim.deliveryId claim.attemptCount [] (DeliveryAccepted (Just (NativeEventId "expired-success")))) `shouldReturn` False
    withDb pool (beginDeliveryPart "parts" claim NonIdempotentParts 0) `shouldReturn` PartRefused "delivery lease lost before part send"
    _ <- withDb pool (claimDeliveriesForLane "unrelated" (LaneUnrouted [PlatformQQ]) 1 120)
    withDb pool (completeDelivery "parts" claim.deliveryId claim.attemptCount [] (DeliveryAccepted (Just (NativeEventId "late")))) `shouldReturn` False

  it "turns a unique self echo into delivery confirmation, not a second message" $ do
    (qq, matrix) <- mirrorPair pool
    now <- getCurrentTime
    original <- withDb pool (ingestEnvelope defaultIngestOptions (inbound matrix.endpointId now "mx-relay" "same body"))
    [claim] <- claimStartedDeliveries pool "worker-a" 10 30
    _ <- withDb pool (completeDelivery "worker-a" claim.deliveryId claim.attemptCount [] (DeliveryUnknown "response lost" now))
    let echo =
          (inbound qq.endpointId (addUTCTime 1 now) "qq-echo" "same body")
            { senderNativeId = NativeUserId "9"
            }
    withDb pool (ingestEnvelope defaultIngestOptions echo) `shouldReturn` DeliveryEcho (resultId original)
    messageCount <- withConn pool $ \conn -> query conn "SELECT count(*) FROM messages" ()
    (messageCount :: [Only Int64]) `shouldBe` [Only 1]
    delivery <- withConn pool $ \conn -> query conn "SELECT status, native_event_id FROM message_deliveries WHERE endpoint_id = ?" (Only qq.endpointId.unEndpointId)
    (delivery :: [(Text, Maybe Text)]) `shouldBe` [("confirmed", Just "qq-echo")]

  it "publishes one bot message and one durable delivery per enabled endpoint" $ do
    (qq, matrix) <- mirrorPair pool
    queued <-
      withDb pool $
        enqueueOutbound
          OutboundDraft
            { legacyConversationId = 42,
              transcriptKind = "chat",
              sourceCanonicalMessageId = Nothing,
              canonicalBody = Body [NText "hello both sides"],
              replyToCanonicalMessageId = Nothing,
              turnOutputLink = Nothing,
              monitorFireId = Nothing
            }
    queued.deliveriesCreated `shouldBe` 2
    claims <- claimStartedDeliveries pool "delivery-worker" 10 30
    fmap (.endpointId) claims `shouldMatchList` [qq.endpointId, matrix.endpointId]
    ledger <- withConn pool $ \conn ->
      query
        conn
        "SELECT m.message_origin, md.status, count(pe.platform_event_id), count(d.delivery_id) \
        \ FROM messages m \
        \ JOIN message_dispatches md USING (canonical_message_id) \
        \ LEFT JOIN platform_events pe USING (canonical_message_id) \
        \ LEFT JOIN message_deliveries d USING (canonical_message_id) \
        \ WHERE m.canonical_message_id = ? \
        \ GROUP BY m.message_origin, md.status"
        (Only queued.canonicalMessageId.unCanonicalMessageId)
    (ledger :: [(Text, Text, Int64, Int64)]) `shouldBe` [("outbound", "ignored", 0, 2)]

  it "publishes outbound reply relations and resolves the target native id" $ do
    conversation <- withDb pool (createConversation ConversationGroup (Just "Matrix only"))
    matrix <-
      withDb pool $
        registerEndpoint
          EndpointRegistration
            { conversationId = conversation,
              platform = PlatformMatrix,
              nativeAccountId = NativeAccountId "@max:example.test",
              accountDisplayName = Just "max",
              nativeConversationId = NativeConversationId "!reply:example.test",
              endpointDisplayName = Just "Reply test",
              conversationKind = ConversationGroup,
              endpointMode = EndpointStandalone,
              capabilities = textCapabilities
            }
    now <- getCurrentTime
    target <- withDb pool (ingestEnvelope defaultIngestOptions (inbound matrix.endpointId now "matrix-target" "target"))
    [Only legacyGroup] <-
      withConn pool $ \conn ->
        query
          conn
          "SELECT group_id FROM messages WHERE canonical_message_id = ?"
          (Only (resultId target).unCanonicalMessageId)
    let targetMessage = (resultId target).unCanonicalMessageId
    queued <-
      withDb pool $
        enqueueOutbound
          OutboundDraft
            { legacyConversationId = legacyGroup,
              transcriptKind = "chat",
              sourceCanonicalMessageId = Nothing,
              canonicalBody = Body [NText "reply"],
              replyToCanonicalMessageId = Just targetMessage,
              turnOutputLink = Nothing,
              monitorFireId = Nothing
            }
    relations <- withConn pool $ \conn ->
      query
        conn
        "SELECT target_canonical_message_id FROM message_relations WHERE canonical_message_id = ? AND relation_kind = 'reply'"
        (Only queued.canonicalMessageId.unCanonicalMessageId)
    (relations :: [Only Int64]) `shouldBe` [Only (resultId target).unCanonicalMessageId]
    claims <- claimStartedDeliveries pool "native-reply" 10 30
    fmap (\delivery -> delivery.replyContext >>= (.nativeId)) claims
      `shouldBe` [Just (NativeEventId "matrix-target")]

  it "fans edit, reaction, and redaction through capable native copies" $ do
    (qq, matrix) <- mirrorPair pool
    now <- getCurrentTime
    metaTarget <-
      withDb pool $
        ingestEnvelope defaultIngestOptions (inbound qq.endpointId now "qq-meta-target" "before")
    [targetCopy] <- claimStartedDeliveries pool "meta-target" 10 30
    targetCopy.endpointId `shouldBe` matrix.endpointId
    withDb
      pool
      (completeDelivery "meta-target" targetCopy.deliveryId targetCopy.attemptCount [] (DeliveryConfirmedAs (Just (NativeEventId "matrix-meta-target"))))
      `shouldReturn` True

    let editEnvelope =
          (inboundBody qq.endpointId (addUTCTime 1 now) "qq-edit" (Body [NText "after"]))
            { eventKind = EventEdit,
              relations = [Replaces (NativeEventId "qq-meta-target")]
            }
    edit <- withDb pool (ingestEnvelope defaultIngestOptions editEnvelope)
    case edit of
      Ingested fresh -> fresh.mirrorDeliveriesCreated `shouldBe` 1
      other -> expectationFailure ("expected new edit: " <> show other)
    [editClaim] <- claimStartedDeliveries pool "meta-edit" 10 30
    editClaim.eventKind `shouldBe` EventEdit
    editClaim.endpointId `shouldBe` matrix.endpointId
    editClaim.actionTarget `shouldBe` Just (NativeEventId "matrix-meta-target")
    editClaim.body `shouldBe` Body [NText "after"]
    withDb pool (completeDelivery "meta-edit" editClaim.deliveryId editClaim.attemptCount [] (DeliveryConfirmedAs (Just (NativeEventId "matrix-edit"))))
      `shouldReturn` True

    let reactionEnvelope =
          (inboundBody matrix.endpointId (addUTCTime 2 now) "matrix-reaction" (Body []))
            { eventKind = EventReaction,
              relations = [ReactsTo (NativeEventId "matrix-meta-target") "212" ReactionAdd]
            }
    reaction <- withDb pool (ingestEnvelope defaultIngestOptions reactionEnvelope)
    case reaction of
      Ingested fresh -> fresh.mirrorDeliveriesCreated `shouldBe` 1
      other -> expectationFailure ("expected new reaction: " <> show other)
    [reactionClaim] <- claimStartedDeliveries pool "meta-reaction" 10 30
    reactionClaim.eventKind `shouldBe` EventReaction
    reactionClaim.endpointId `shouldBe` qq.endpointId
    reactionClaim.actionTarget `shouldBe` Just (NativeEventId "qq-meta-target")
    reactionClaim.reactionKey `shouldBe` Just "212"
    reactionClaim.reactionAction `shouldBe` ReactionAdd
    withDb pool (completeDelivery "meta-reaction" reactionClaim.deliveryId reactionClaim.attemptCount [] (DeliveryConfirmedAs Nothing))
      `shouldReturn` True

    let redactionEnvelope =
          (inboundBody qq.endpointId (addUTCTime 3 now) "qq-redaction" (Body []))
            { eventKind = EventRedaction,
              relations = [Redacts (NativeEventId "qq-meta-target")]
            }
    redaction <- withDb pool (ingestEnvelope defaultIngestOptions redactionEnvelope)
    case redaction of
      Ingested fresh -> fresh.mirrorDeliveriesCreated `shouldBe` 1
      other -> expectationFailure ("expected new redaction: " <> show other)
    [redactionClaim] <- claimStartedDeliveries pool "meta-redaction" 10 30
    redactionClaim.eventKind `shouldBe` EventRedaction
    redactionClaim.endpointId `shouldBe` matrix.endpointId
    redactionClaim.actionTarget `shouldBe` Just (NativeEventId "matrix-meta-target")

    -- A meta event has no content nodes, so its stored projection can only
    -- come from the relation.  Before this it was the empty string, which is
    -- why the transcript could not show these at all — and the target is
    -- named with the canonical id the model already uses everywhere else.
    let targetId = (resultId metaTarget).unCanonicalMessageId
    projections <- withConn pool $ \conn ->
      query
        conn
        "SELECT event_kind, rendered_text FROM messages \
        \ WHERE event_kind <> 'message' ORDER BY canonical_message_id"
        ()
    (projections :: [(Text, Text)])
      `shouldBe` [ ("edit", "[edit#" <> tshow targetId <> "]"),
                   ("reaction", "[react#" <> tshow targetId <> ": 托腮]"),
                   ("redaction", "[unsend#" <> tshow targetId <> "]")
                 ]

  it "uses the total capability decoder for meta fan-out" $ do
    (qq, matrix) <- mirrorPair pool
    now <- getCurrentTime
    _ <-
      withDb pool $
        ingestEnvelope defaultIngestOptions (inbound qq.endpointId now "qq-meta-malformed-target" "before")
    [targetCopy] <- claimStartedDeliveries pool "meta-malformed-target" 10 30
    withDb
      pool
      (completeDelivery "meta-malformed-target" targetCopy.deliveryId targetCopy.attemptCount [] (DeliveryConfirmedAs (Just (NativeEventId "matrix-meta-malformed-target"))))
      `shouldReturn` True
    _ <- withConn pool $ \conn ->
      execute
        conn
        "UPDATE conversation_endpoints SET capabilities = '\"malformed\"'::jsonb WHERE endpoint_id = ?"
        (Only matrix.endpointId.unEndpointId)
    let editEnvelope =
          (inboundBody qq.endpointId (addUTCTime 1 now) "qq-malformed-edit" (Body [NText "after"]))
            { eventKind = EventEdit,
              relations = [Replaces (NativeEventId "qq-meta-malformed-target")]
            }
    edit <- withDb pool (ingestEnvelope defaultIngestOptions editEnvelope)
    case edit of
      Ingested fresh -> fresh.mirrorDeliveriesCreated `shouldBe` 0
      other -> expectationFailure ("expected new edit: " <> show other)
    claimStartedDeliveries pool "meta-malformed-edit" 10 30 `shouldReturn` []

  it "publishes bot QQ reactions idempotently and reconciles their notice echo" $ do
    (qq, _) <- mirrorPair pool
    now <- getCurrentTime
    target <-
      withDb pool $
        ingestEnvelope
          defaultIngestOptions {createMirrorDeliveries = False}
          (inbound qq.endpointId now "qq-reaction-target" "target")
    let targetMessage = (resultId target).unCanonicalMessageId
    caps <- withDb pool (conversationAdvertisedCaps 42 (Just targetMessage))
    caps.canReaction `shouldBe` True
    missingCaps <- withDb pool (conversationAdvertisedCaps 42 (Just 999999999))
    missingCaps.canReaction `shouldBe` False
    let draft =
          ReactionDraft
            { legacyConversationId = 42,
              targetCanonicalMessageId = targetMessage,
              reactionKey = "212",
              reactionAction = ReactionAdd,
              requiredPlatform = Just PlatformQQ
            }
    Just queued <- withDb pool (enqueueReaction draft)
    queued.deliveriesCreated `shouldBe` 1
    withDb pool (enqueueReaction draft) `shouldReturn` Just queued
    [claim] <- claimStartedDeliveries pool "bot-reaction" 10 30
    claim.eventKind `shouldBe` EventReaction
    claim.endpointId `shouldBe` qq.endpointId
    claim.actionTarget `shouldBe` Just (NativeEventId "qq-reaction-target")
    withDb pool (completeDelivery "bot-reaction" claim.deliveryId claim.attemptCount [] (DeliveryConfirmedAs Nothing))
      `shouldReturn` True
    let echo =
          (inboundBody qq.endpointId (addUTCTime 1 now) "qq-reaction-notice" (Body []))
            { senderNativeId = NativeUserId "9",
              eventKind = EventReaction,
              relations = [ReactsTo (NativeEventId "qq-reaction-target") "212" ReactionAdd]
            }
    withDb pool (ingestEnvelope defaultIngestOptions echo)
      `shouldReturn` DeliveryEcho queued.canonicalMessageId
    rows <- withConn pool $ \conn ->
      query conn "SELECT count(*) FROM messages" ()
    (rows :: [Only Int64]) `shouldBe` [Only 2]

  it "quietly declines bot reactions when the sole decoder rejects endpoint capabilities" $ do
    (qq, _) <- mirrorPair pool
    now <- getCurrentTime
    target <-
      withDb pool $
        ingestEnvelope
          defaultIngestOptions {createMirrorDeliveries = False}
          (inbound qq.endpointId now "qq-malformed-reaction-target" "target")
    let targetMessage = (resultId target).unCanonicalMessageId
    _ <- withConn pool $ \conn ->
      execute
        conn
        "UPDATE conversation_endpoints SET capabilities = '\"malformed\"'::jsonb WHERE endpoint_id = ?"
        (Only qq.endpointId.unEndpointId)
    let draft =
          ReactionDraft
            { legacyConversationId = 42,
              targetCanonicalMessageId = targetMessage,
              reactionKey = "212",
              reactionAction = ReactionAdd,
              requiredPlatform = Just PlatformQQ
            }
    withDb pool (enqueueReaction draft) `shouldReturn` Nothing
    rows <- withConn pool $ \conn -> query conn "SELECT count(*) FROM messages" ()
    (rows :: [Only Int64]) `shouldBe` [Only 1]

  it "keeps semantic mentions when a mirror has a QQ endpoint" $ do
    (qq, matrix) <- mirrorPair pool
    mirrorCaps <- withDb pool (conversationAdvertisedCaps 42 Nothing)
    mirrorCaps.canReply `shouldBe` True
    mirrorCaps.canMention `shouldBe` True
    mirrorCaps.canFace `shouldBe` True
    -- Mention content has a readable per-endpoint fallback; faces do not.
    -- Endpoint identities, not the positive legacy group id, decide this.
    qq.endpointId `shouldNotBe` matrix.endpointId

  it "keeps command output on the endpoint that supplied the source message" $ do
    (qq, matrix) <- mirrorPair pool
    now <- getCurrentTime
    source <-
      withDb pool $
        ingestEnvelope
          defaultIngestOptions {createMirrorDeliveries = False}
          (inbound matrix.endpointId now "mx-command" "!status")
    let sourceMessage = (resultId source).unCanonicalMessageId
    queued <-
      withDb pool $
        enqueueOutbound
          OutboundDraft
            { legacyConversationId = 42,
              transcriptKind = "command",
              sourceCanonicalMessageId = Just sourceMessage,
              canonicalBody = Body [NText "status"],
              replyToCanonicalMessageId = Nothing,
              turnOutputLink = Nothing,
              monitorFireId = Nothing
            }
    queued.deliveriesCreated `shouldBe` 1
    claims <- claimStartedDeliveries pool "local-command" 10 30
    fmap (.endpointId) claims `shouldBe` [matrix.endpointId]
    fmap (.endpointId) claims `shouldNotContain` [qq.endpointId]

  it "redacts secrets before bounding diagnostic raw payloads" $ do
    let raw = object ["access_token" .= ("secret-value" :: Text), "body" .= ("hello" :: Text)]
        (small, smallTruncated) = sanitizeRawPayload 4096 (Just raw)
        (bounded, boundedTruncated) = sanitizeRawPayload 8 (Just raw)
    smallTruncated `shouldBe` False
    show small `shouldNotContain` "secret-value"
    boundedTruncated `shouldBe` True
    show bounded `shouldNotContain` "secret-value"

  it "normalizes PostgreSQL-forbidden NULs across the complete ingest envelope" $ do
    (_, matrix) <- mirrorPair pool
    now <- getCurrentTime
    let envelope =
          (inbound matrix.endpointId now "imsg-\0-event" "hello\0world")
            { senderNativeId = NativeUserId "alice\0id",
              senderDisplayName = Just "Ali\0ce",
              sourceCursor = Just (PlatformCursor (object ["cursor\0key" .= ("next\0page" :: Text)])),
              rawPayload = Just (object ["nested" .= object ["body" .= ("raw\0body" :: Text)]])
            }
        options =
          defaultIngestOptions
            { qqProvenanceSegments = Just (object ["text" .= ("segment\0text" :: Text)])
            }
    result <- withDb pool (ingestEnvelope options envelope)
    rows <- withConn pool $ \conn ->
      query
        conn
        "SELECT pe.native_event_id, pe.source_cursor::text, pe.raw_payload::text, \
        \       m.rendered_text, m.raw_message, coalesce(m.sender_nickname, ''), \
        \       m.canonical_content::text, m.segments::text \
        \ FROM platform_events pe \
        \ JOIN messages m USING (canonical_message_id) \
        \ WHERE m.canonical_message_id = ?"
        (Only (resultId result).unCanonicalMessageId)
    case rows :: [(Text, Text, Text, Text, Text, Text, Text, Text)] of
      [fields] -> do
        let persisted = T.intercalate "|" (tuple8ToList fields)
        persisted `shouldSatisfy` T.isInfixOf "\xfffd"
        persisted `shouldNotSatisfy` T.any (== '\NUL')
      _ -> expectationFailure "missing sanitized canonical event"

  -- A forward's children point at their container with a @contained_in@
  -- relation, and a relation names its target /natively/.  The forward worker
  -- holds the container only as a canonical id, so it has to translate before
  -- it can parent onto it — spelling the canonical id into the native column
  -- inserts a row that never resolves, and 'fetchForwardChildrenInScope' joins
  -- on exactly the column that stays null.  The container then reads as an
  -- unexpanded forward no matter how many children landed under it.
  it "resolves a forward child onto its container through the native id" $ do
    (qq, _) <- mirrorPair pool
    now <- getCurrentTime
    container <- withDb pool (ingestEnvelope defaultIngestOptions (inbound qq.endpointId now "container-event" "[forward]"))
    let containerId = (resultId container).unCanonicalMessageId
    native <- withDb pool (nativeEventIdForCanonical (resultId container))
    native `shouldBe` NativeEventId "container-event"
    _ <-
      withDb pool $
        ingestEnvelope
          defaultIngestOptions
          (inbound qq.endpointId now "child-event" "quoted line")
            { relations = [ContainedIn native 0]
            }
    children <- withDb pool (fetchForwardChildrenInScope (conversationScopeFor (GroupId 42)) containerId 10)
    map (.renderedText) children `shouldBe` ["quoted line"]

    -- The regression itself: parenting onto the canonical id inserts an
    -- unresolved row, and the reader cannot see the child at all.
    _ <-
      withDb pool $
        ingestEnvelope
          defaultIngestOptions
          (inbound qq.endpointId now "stray-event" "orphaned line")
            { relations = [ContainedIn (NativeEventId (T.pack (show containerId))) 1]
            }
    stillOne <- withDb pool (fetchForwardChildrenInScope (conversationScopeFor (GroupId 42)) containerId 10)
    map (.renderedText) stillOne `shouldBe` ["quoted line"]

  -- A recall or reaction notice names only a user id, and QQ spells an unset
  -- 群名片 as @""@ rather than omitting it.  Either way the envelope arrives
  -- without a name, and the row must still be readable: an unnamed row reads
  -- back as a bare principal id, and one such row being a speaker's newest
  -- line puts a number in the prompt roster.
  it "names an event that carries no name from the sender's identity" $ do
    (_, endpoint) <- mirrorPair pool
    now <- getCurrentTime
    named <- withDb pool (ingestEnvelope defaultIngestOptions (inbound endpoint.endpointId now "named-event" "hi"))
    anonymous <-
      withDb pool $
        ingestEnvelope
          defaultIngestOptions
          (withoutSenderDisplay (inbound endpoint.endpointId now "anonymous-event" "again"))
    let nameOf result = withConn pool $ \conn ->
          query
            conn
            "SELECT coalesce(sender_nickname, '') FROM messages WHERE canonical_message_id = ?"
            (Only (resultId result).unCanonicalMessageId)
    nameOf named `shouldReturn` [Only ("Alice" :: Text)]
    nameOf anonymous `shouldReturn` [Only ("Alice" :: Text)]

  it "repairs blank QQ image projections and recreates their fetch jobs" $ do
    endpoint <-
      withDb pool $
        ensureLegacyEndpoint
          PlatformQQ
          (NativeAccountId "9")
          (NativeConversationId "42")
          ConversationGroup
          42
          textCapabilities
    now <- getCurrentTime
    let imageUrl = "https://qq.example/image.jpg"
        options :: IngestOptions
        options =
          defaultIngestOptions
            { PlatformStore.qqProvenanceSegments =
                Just . toJSON $
                  [ object
                      [ "type" .= ("image" :: Text),
                        "data"
                          .= object
                            [ "file" .= imageUrl,
                              "summary" .= ("" :: Text),
                              "sub_type" .= (0 :: Int)
                            ]
                      ]
                  ]
            }
        envelope :: InboundEnvelope
        envelope =
          inboundBody endpoint.endpointId now "qq-image-roundtrip" $
            Body
              [ NMedia
                  (mediaRemoteRef imageUrl)
                  MediaMeta
                    { kind = MImage,
                      mime = Nothing,
                      sizeBytes = Nothing,
                      name = Nothing,
                      description = Nothing,
                      raw = Nothing
                    }
              ]
    result <- withDb pool (ingestEnvelope options envelope)
    -- The 053 defect class is unrepresentable now: a blank caption never
    -- becomes transcript text, and the stored v2 node keeps its source.
    rows <- withConn pool $ \conn ->
      query
        conn
        "SELECT rendered_text, canonical_content->>'v', \
        \       canonical_content->'nodes'->0->>'type', \
        \       canonical_content->'nodes'->0->>'source' \
        \ FROM messages WHERE canonical_message_id = ?"
        (Only (resultId result).unCanonicalMessageId)
    (rows :: [(Text, Text, Text, Text)])
      `shouldBe` [("[image]", "2", "media", imageUrl)]

  it "keeps the structural QQ mention projection and resolves its principal identity" $ do
    endpoint <-
      withDb pool $
        ensureLegacyEndpoint
          PlatformQQ
          (NativeAccountId "9")
          (NativeConversationId "42")
          ConversationGroup
          42
          textCapabilities
    now <- getCurrentTime
    let envelope :: InboundEnvelope
        envelope =
          inboundBody endpoint.endpointId now "qq-mention-projection" $
            Body
              [ NMention (NativeUserId "2291939848") "2291939848",
                NText " hello"
              ]
    result <- withDb pool (ingestEnvelope defaultIngestOptions envelope)
    -- The 054 defect class is unrepresentable now: the prompt projection
    -- is structural by construction, and the stored mention carries a
    -- resolved principal identity instead of a bare native id.
    rows <- withConn pool $ \conn ->
      query
        conn
        "SELECT m.rendered_text, m.canonical_content->'nodes'->0->>'display', \
        \       pi.native_user_id, pi.principal_id \
        \ FROM messages m \
        \ JOIN principal_identities pi \
        \   ON pi.principal_identity_id = (m.canonical_content->'nodes'->0->>'identity')::bigint \
        \ WHERE m.canonical_message_id = ?"
        (Only (resultId result).unCanonicalMessageId)
    -- The mention names the person; 2291939848 is the account it resolved
    -- through, which only the identity row still knows about.
    case rows :: [(Text, Text, Text, Int64)] of
      [(rendered, display, native, principal)] ->
        (rendered, display, native) `shouldBe` ("[mention#" <> tshow principal <> "] hello", "2291939848", "2291939848")
      other -> expectationFailure ("unexpected projection rows: " <> show other)

  it "enriches an identity first discovered through a bare mention" $ do
    endpoint <-
      withDb pool $
        ensureLegacyEndpoint
          PlatformQQ
          (NativeAccountId "9")
          (NativeConversationId "42")
          ConversationGroup
          42
          textCapabilities
    now <- getCurrentTime
    _ <-
      withDb pool $
        ingestEnvelope
          defaultIngestOptions
          ( inboundBody endpoint.endpointId now "mention-before-profile" $
              Body [NMention (NativeUserId "2291939848") "2291939848"]
          )
    _ <-
      withDb pool $
        ingestEnvelope
          defaultIngestOptions
          ( (inbound endpoint.endpointId now "profile-arrives" "hello")
              { senderNativeId = NativeUserId "2291939848",
                senderDisplayName = Just "张三"
              }
          )
    later <-
      withDb pool $
        ingestEnvelope
          defaultIngestOptions
          ( inboundBody endpoint.endpointId now "mention-after-profile" $
              Body [NMention (NativeUserId "2291939848") "2291939848"]
          )
    rows <- withConn pool $ \conn ->
      query
        conn
        "SELECT pi.display_name, p.display_name, \
        \       m.canonical_content->'nodes'->0->>'display' \
        \ FROM principal_identities pi \
        \ JOIN principals p USING (principal_id) \
        \ JOIN messages m ON m.canonical_message_id = ? \
        \ WHERE pi.platform_account_id = ? AND pi.native_user_id = ?"
        ( (resultId later).unCanonicalMessageId,
          endpoint.platformAccountId.unPlatformAccountId,
          "2291939848" :: Text
        )
    (rows :: [(Maybe Text, Maybe Text, Text)])
      `shouldBe` [(Just "张三", Just "张三", "张三")]

  -- Ingest used to render the prompt projection from the pre-identity ingest
  -- body while `maintenance verify`/`reproject` recompute it from the stored
  -- canonical body.  On any platform whose mention token carries the display
  -- name, enrichment made the two disagree and a correct row read as stale.
  it "renders the prompt projection from the enriched canonical body" $ do
    conversation <- withDb pool (createConversation ConversationGroup (Just "Matrix only"))
    matrix <-
      withDb pool $
        registerEndpoint
          EndpointRegistration
            { conversationId = conversation,
              platform = PlatformMatrix,
              nativeAccountId = NativeAccountId "@max:example.test",
              accountDisplayName = Just "max",
              nativeConversationId = NativeConversationId "!projection:example.test",
              endpointDisplayName = Just "Projection test",
              conversationKind = ConversationGroup,
              endpointMode = EndpointStandalone,
              capabilities = textCapabilities
            }
    now <- getCurrentTime
    _ <-
      withDb pool $
        ingestEnvelope
          defaultIngestOptions
          ( (inbound matrix.endpointId now "mx-profile" "hello")
              { senderNativeId = NativeUserId "@zhang:example.test",
                senderDisplayName = Just "张三"
              }
          )
    mention <-
      withDb pool $
        ingestEnvelope
          defaultIngestOptions
          ( inboundBody matrix.endpointId (addUTCTime 1 now) "mx-mention" $
              Body
                [ NMention (NativeUserId "@zhang:example.test") "@zhang:example.test",
                  NText " 在吗"
                ]
          )
    rows <- withConn pool $ \conn ->
      query
        conn
        "SELECT m.rendered_text, m.canonical_content->'nodes'->0->>'display', pi.principal_id \
        \ FROM messages m \
        \ JOIN principal_identities pi \
        \   ON pi.principal_identity_id = (m.canonical_content->'nodes'->0->>'identity')::bigint \
        \ WHERE m.canonical_message_id = ?"
        (Only (resultId mention).unCanonicalMessageId)
    case rows :: [(Text, Text, Int64)] of
      [(rendered, display, principal)] ->
        (rendered, display) `shouldBe` ("[mention#" <> tshow principal <> "] 在吗", "张三")
      other -> expectationFailure ("unexpected projection rows: " <> show other)

  -- The WeChat relay acknowledges a send without an id; the bot's own message
  -- coming back on the sync stream is the only receipt it ever gets.
  it "confirms a receipt-less send from an endpoint whose self events are echoes" $ do
    conversation <- withDb pool (createConversation ConversationGroup (Just "Echo only"))
    endpoint <-
      withDb pool $
        registerEndpoint
          EndpointRegistration
            { conversationId = conversation,
              platform = PlatformWeChatHook,
              nativeAccountId = NativeAccountId "wxid_max",
              accountDisplayName = Just "max",
              nativeConversationId = NativeConversationId "room@chatroom",
              endpointDisplayName = Just "Echo room",
              conversationKind = ConversationGroup,
              endpointMode = EndpointStandalone,
              capabilities = textCapabilities
            }
    now <- getCurrentTime
    seed <- withDb pool (ingestEnvelope defaultIngestOptions (inbound endpoint.endpointId now "wx-seed" "trigger"))
    [Only legacyGroup] <-
      withConn pool $ \conn ->
        query
          conn
          "SELECT group_id FROM messages WHERE canonical_message_id = ?"
          (Only (resultId seed).unCanonicalMessageId) ::
          IO [Only Int64]
    queued <-
      withDb pool $
        enqueueOutbound
          OutboundDraft
            { legacyConversationId = legacyGroup,
              transcriptKind = "chat",
              sourceCanonicalMessageId = Nothing,
              canonicalBody = Body [NText "我在"],
              replyToCanonicalMessageId = Nothing,
              turnOutputLink = Nothing,
              monitorFireId = Nothing
            }
    [claim] <- claimStartedDeliveries pool "wechat-worker" 10 30
    withDb pool (completeDelivery "wechat-worker" claim.deliveryId claim.attemptCount [] (DeliveryAccepted Nothing))
      `shouldReturn` True
    let echo eventId body =
          (inboundBody endpoint.endpointId (addUTCTime 1 now) eventId (Body [NText body]))
            { senderNativeId = NativeUserId "wxid_max"
            }
    withDb
      pool
      (ingestEnvelope defaultIngestOptions {selfEventsAreEchoes = True} (echo "wx-echo" "我在"))
      `shouldReturn` DeliveryEcho queued.canonicalMessageId
    delivery <- withConn pool $ \conn ->
      query
        conn
        "SELECT status, native_event_id FROM message_deliveries WHERE delivery_id = ?"
        (Only claim.deliveryId.unDeliveryId)
    (delivery :: [(Text, Maybe Text)]) `shouldBe` [("confirmed", Just "wx-echo")]

    -- An echo that matches nothing stores nothing: the bot's own line already
    -- exists as an outbound row, and a second copy would be transcript noise.
    before' <- storedMessageCount
    withDb
      pool
      (ingestEnvelope defaultIngestOptions {selfEventsAreEchoes = True} (echo "wx-stray" "谁在说话"))
      `shouldReturn` EchoUnmatched
    after' <- storedMessageCount
    after' `shouldBe` before'
  where
    storedMessageCount = do
      rows <- withConn pool $ \conn -> query conn "SELECT count(*) FROM messages" ()
      pure (rows :: [Only Int64])

mirrorPair :: DbPool -> IO (RegisteredEndpoint, RegisteredEndpoint)
mirrorPair pool = withDb pool $ do
  conversation <- createConversation ConversationGroup (Just "mirror test")
  qq <-
    registerEndpoint
      EndpointRegistration
        { conversationId = conversation,
          platform = PlatformQQ,
          nativeAccountId = NativeAccountId "9",
          accountDisplayName = Just "max",
          nativeConversationId = NativeConversationId "42",
          endpointDisplayName = Just "QQ test",
          conversationKind = ConversationGroup,
          endpointMode = EndpointMirror,
          capabilities = textCapabilities {reaction = True}
        }
  matrix <-
    registerEndpoint
      EndpointRegistration
        { conversationId = conversation,
          platform = PlatformMatrix,
          nativeAccountId = NativeAccountId "@max:example.test",
          accountDisplayName = Just "max",
          nativeConversationId = NativeConversationId "!room:example.test",
          endpointDisplayName = Just "Matrix test",
          conversationKind = ConversationGroup,
          endpointMode = EndpointMirror,
          capabilities = textCapabilities {reaction = True, edit = True, redact = True}
        }
  pure (qq, matrix)

textCapabilities :: OutboundCaps
textCapabilities =
  textOnlyCaps
    { reply = TierNative,
      maxTextBytes = Just 32768
    }

inbound :: EndpointId -> UTCTime -> Text -> Text -> InboundEnvelope
inbound endpoint now eventId body =
  inboundBody endpoint now eventId (Body [NText body])

inboundBody :: EndpointId -> UTCTime -> Text -> Body 'Ingest -> InboundEnvelope
inboundBody endpoint now eventId body =
  InboundEnvelope
    { endpointId = endpoint,
      nativeEventId = NativeEventId eventId,
      senderNativeId = NativeUserId "@alice:example.test",
      senderDisplayName = Just "Alice",
      occurredAt = addUTCTime (-1) now,
      receivedAt = now,
      eventKind = EventMessage,
      ingestClass = LiveDelivery,
      content = body,
      relations = [],
      sourceCursor = Just (PlatformCursor (String "next")),
      rawPayload = Just (object ["event_id" .= eventId])
    }

withTranscriptKind :: Text -> IngestOptions -> IngestOptions
withTranscriptKind kind (IngestOptions raw dispatch mirrors _ provenance echoes) =
  IngestOptions raw dispatch mirrors kind provenance echoes

withoutSenderDisplay :: InboundEnvelope -> InboundEnvelope
withoutSenderDisplay (InboundEnvelope eid native sender _ occurred received kind ingest body relations cursor raw) =
  InboundEnvelope eid native sender Nothing occurred received kind ingest body relations cursor raw

isNew :: IngestResult -> Bool
isNew (Ingested _) = True
isNew _ = False

isDuplicate :: IngestResult -> Bool
isDuplicate (AlreadyIngested _) = True
isDuplicate _ = False

-- | The attempt a claim came back with, which is the fence every settle and
-- every renewal of that claim has to present.
claimAttempt :: Maybe DispatchClaim -> IO Int
claimAttempt (Just claim) = pure claim.attemptCount
claimAttempt Nothing = expectationFailure "expected a dispatch claim" >> pure 0

-- | Most delivery tests exercise the pre-reservation contract: once a claim
-- was returned it was already in the non-idempotent sending phase.  Keep those
-- assertions explicit while production now reserves a batch and starts each
-- member just in time.
claimStartedDeliveries :: DbPool -> Text -> Int -> NominalDiffTime -> IO [DeliveryClaim]
claimStartedDeliveries pool owner limit lease = do
  claims <- withDb pool (claimDeliveries owner limit lease)
  forM_ claims $ \claim ->
    withDb pool (startDelivery owner claim.deliveryId claim.attemptCount lease)
      `shouldReturn` True
  pure claims

claimStartedDispatch :: DbPool -> Text -> CanonicalMessageId -> NominalDiffTime -> IO (Maybe DispatchClaim)
claimStartedDispatch pool owner message lease = do
  claimed <- withDb pool (claimDispatch owner message lease)
  forM_ claimed $ \claim ->
    withDb pool (startDispatch owner message claim.attemptCount lease)
      `shouldReturn` True
  pure claimed

tuple8ToList :: (a, a, a, a, a, a, a, a) -> [a]
tuple8ToList (a, b, c, d, e, f, g, h) = [a, b, c, d, e, f, g, h]

-- | Every delivery queued against one endpoint, as @(status, idempotency key)@.
deliveriesFor :: DbPool -> EndpointId -> IO [(Text, Text)]
deliveriesFor pool (EndpointId endpoint) =
  withConn pool $ \conn ->
    query
      conn
      "SELECT status, idempotency_key FROM message_deliveries \
      \ WHERE endpoint_id = ? ORDER BY delivery_id"
      (Only endpoint)

ledgerCounts :: DbPool -> EndpointId -> EndpointId -> IO (Int64, Int64, Int64, Int64, Int64)
ledgerCounts pool (EndpointId source) (EndpointId target) = withConn pool $ \conn -> do
  rows <-
    query
      conn
      "SELECT \
      \ (SELECT count(*) FROM messages), \
      \ (SELECT count(*) FROM platform_events), \
      \ (SELECT count(*) FROM message_dispatches WHERE status = 'pending'), \
      \ (SELECT count(*) FROM message_deliveries WHERE endpoint_id = ? AND status = 'confirmed'), \
      \ (SELECT count(*) FROM message_deliveries WHERE endpoint_id = ? AND status = 'pending')"
      (source, target)
  case rows of
    [counts] -> pure counts
    _ -> error "ledgerCounts: expected one row"
