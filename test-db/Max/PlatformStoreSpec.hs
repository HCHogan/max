module Max.PlatformStoreSpec (spec) where

import Control.Concurrent.Async (concurrently, link, withAsync)
import Control.Concurrent.MVar (newEmptyMVar, takeMVar, tryPutMVar)
import Control.Monad (forM, forM_, void)
import Data.Aeson (Value (..), decode, encode, object, toJSON, (.=))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Char8 qualified as BS
import Data.IORef
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime, addUTCTime, getCurrentTime)
import Database.PostgreSQL.Simple (Only (..), execute, query)
import Database.PostgreSQL.Simple.FromField (ResultError (..))
import Database.PostgreSQL.Simple.Types (PGArray (..))
import Helpers (resultId, truncateAll, withDb, withDbLog)
import Max.ConversationScope (conversationScopeFor)
import Max.DB.Connection (DbPool, withConn)
import Max.DB.History (HistoryItem (..), fetchForwardChildrenInScope)
import Max.Dispatch (DispatchMessage (canonicalId))
import Max.HttpRuntime (httpRuntimeFromManagers, newHttpRuntime)
import Max.IMessage (IMessageConfig (..), iMessageWorker)
import Max.IR
import Max.IR.Lower
import Max.Matrix (MatrixConfig (..), matrixDeliveryTransport)
import Max.Platform (PlatformBackend (..))
import Max.Platform.Delivery (DeliveryOperation (..), DeliveryTransport (..), oneBotDeliveryTransport)
import Max.Platform.Delivery.Parts
import Max.Platform.Delivery.Queue
import Max.Platform.Delivery.Store
import Max.Platform.Envelope (InboundEnvelope (..), IngestClass (Backfill, LiveDelivery))
import Max.Platform.Ingress (newIngress, nextIngress, queueIngest)
import Max.Platform.Store
import Max.Platform.Store qualified as PlatformStore
import Max.Platform.Types
import Max.Util (tshow)
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Types (status200, status503)
import Network.Wai qualified as Wai
import Network.Wai.Handler.Warp qualified as Warp
import OneBot.Action (Action (..), Response (..))
import OneBot.Types (GroupId (..))
import System.Directory (doesFileExist)
import System.Timeout (timeout)
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
    claims <- startPendingDeliveries pool
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
    claims <- startPendingDeliveries pool
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
    claims <- startPendingDeliveries pool
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

    (messages, events, sourceConfirmed, mirrorPending) <-
      ledgerCounts pool matrix.endpointId qq.endpointId
    messages `shouldBe` 1
    events `shouldBe` 1
    outgoing <- newDeliveryQueue (DeliveryId 0)
    ingress <- newIngress outgoing
    mapM_ (queueIngest ingress) [left, right]
    nextIngress ingress `shouldReturn` resultId left
    timeout 10000 (nextIngress ingress) `shouldReturn` Nothing
    mirrored <- nextDelivery outgoing (const True)
    mirrored.target.endpointId `shouldBe` qq.endpointId
    timeout 10000 (nextDelivery outgoing (const True)) `shouldReturn` Nothing
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
    [claim] <- startPendingDeliveries pool
    withDb
      pool
      ( completeDelivery
          claim.deliveryId
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
    [claim] <- startPendingDeliveries pool
    claim.endpointId `shouldBe` qq.endpointId
    _ <- withDb pool (completeDelivery claim.deliveryId [] (DeliveryUnknown "timeout" now))
    statuses <- withDb pool listPlatformStatus
    case [status | status <- statuses, status.endpointId == qq.endpointId] of
      [status] -> status.outcomeUnknownDeliveries `shouldBe` 1
      _ -> expectationFailure "missing QQ endpoint status"
    case [status | status <- statuses, status.endpointId == matrix.endpointId] of
      [status] -> do
        status.pendingDeliveries `shouldBe` 0
        show status.cursors `shouldContain` "s1"
      _ -> expectationFailure "missing Matrix endpoint status"

  -- The retry budget in Max.Platform.Delivery converts an exhausted retryable
  -- attempt into a permanent failure precisely so the endpoint's ordered lane
  -- stops waiting on a copy that can never land.  That only works if a terminal
  -- row leaves the blocking set.
  it "releases the ordered lane once a poisoned copy permanently fails" $ do
    (qq, matrix) <- mirrorPair pool
    now <- getCurrentTime
    _ <- withDb pool (ingestEnvelope defaultIngestOptions (inbound matrix.endpointId now "mx-poison" "risk controlled"))
    _ <- withDb pool (ingestEnvelope defaultIngestOptions (inbound matrix.endpointId (addUTCTime 1 now) "mx-after" "queued behind it"))
    [poisoned] <- startPendingDeliveries pool
    poisoned.endpointId `shouldBe` qq.endpointId
    -- Its successor stays blocked while the head is retryable.
    withDb pool (completeDelivery poisoned.deliveryId [] (DeliveryRetry "retcode 1200" now))
      `shouldReturn` True
    [retried] <- startPendingDeliveries pool
    retried.deliveryId `shouldBe` poisoned.deliveryId
    withDb
      pool
      (completeDelivery retried.deliveryId [] (DeliveryPermanentlyFailed "retry budget exhausted after 16 attempts: retcode 1200"))
      `shouldReturn` True
    rows <- withConn pool $ \conn ->
      query
        conn
        "SELECT status FROM message_deliveries WHERE delivery_id = ?"
        (Only retried.deliveryId.unDeliveryId)
    (rows :: [Only Text]) `shouldBe` [Only "permanent_failure"]
    released <- startPendingDeliveries pool
    fmap (.canonicalMessageId) released `shouldSatisfy` ((== 1) . length)
    released `shouldSatisfy` all ((/= poisoned.deliveryId) . (.deliveryId))

  it "reports deterministic poison separately from deliberate suppression" $ do
    (qq, matrix) <- mirrorPair pool
    now <- getCurrentTime
    _ <- withDb pool (ingestEnvelope defaultIngestOptions (inbound matrix.endpointId now "mx-permanent" "poison"))
    [poisoned] <- startPendingDeliveries pool
    withDb
      pool
      (completeDelivery poisoned.deliveryId [] (DeliveryPermanentlyFailed "invalid target"))
      `shouldReturn` True
    _ <- withDb pool (ingestEnvelope defaultIngestOptions (inbound matrix.endpointId (addUTCTime 1 now) "mx-suppressed" "policy"))
    [suppressed] <- startPendingDeliveries pool
    withDb
      pool
      (completeDelivery suppressed.deliveryId [] (DeliverySuppressedAs "reaction unsupported"))
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
    [claim] <- startPendingDeliveries pool
    let notes = [LowerNote "mention" NoteFolded (Just "no identity on endpoint")]
    withDb pool (completeDelivery claim.deliveryId notes (DeliveryConfirmedAs Nothing))
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
    firstClaims <- startPendingDeliveries pool
    firstClaims `shouldSatisfy` \case
      [claim] -> claim.endpointId == qq.endpointId && claim.body == Body [NText "first"]
      _ -> False
    case firstClaims of
      [firstClaim] -> do
        withDb pool (completeDelivery firstClaim.deliveryId [] (DeliveryAccepted (Just (NativeEventId "reused-native"))))
          `shouldReturn` True
        secondClaims <- startPendingDeliveries pool
        secondClaims `shouldSatisfy` \case
          [claim] -> claim.endpointId == qq.endpointId && claim.body == Body [NText "second"]
          _ -> False
        secondClaim <- case secondClaims of
          [claim] -> pure claim
          _ -> expectationFailure "expected the second ordered delivery" >> fail "unreachable"
        withDb pool (completeDelivery secondClaim.deliveryId [] (DeliveryAccepted (Just (NativeEventId "reused-native"))))
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
    [claim] <- startPendingDeliveries pool
    claim.endpointId `shouldBe` qq.endpointId
    unknown <-
      withDb pool $
        completeDelivery claim.deliveryId [] (DeliveryUnknown "timeout after write" (addUTCTime (-1) now))
    unknown `shouldBe` True
    startPendingDeliveries pool `shouldReturn` []

  it "requeues an accepted send only after explicit provider failure evidence" $ do
    (qq, matrix) <- mirrorPair pool
    now <- getCurrentTime
    _ <- withDb pool (ingestEnvelope defaultIngestOptions (inbound qq.endpointId now "qq-reconcile" "status me"))
    [claim] <- startPendingDeliveries pool
    claim.endpointId `shouldBe` matrix.endpointId
    accepted <-
      withDb pool $
        completeDelivery claim.deliveryId [] (DeliveryAccepted (Just (NativeEventId "native-out")))
    accepted `shouldBe` True
    startPendingDeliveries pool `shouldReturn` []
    unconfirmed <- withDb pool (listUnconfirmedDeliveries PlatformMatrix 10)
    fmap (.deliveryId) unconfirmed `shouldBe` [claim.deliveryId]
    withDb pool (confirmUnconfirmedDelivery claim.deliveryId (NativeEventId "wrong")) `shouldReturn` False
    withDb pool (retryUnconfirmedDelivery claim.deliveryId (NativeEventId "native-out") "provider failed")
      `shouldReturn` True
    retried <- startPendingDeliveries pool
    fmap (.deliveryId) retried `shouldBe` [claim.deliveryId]

  it "confirms an accepted send through a status reconciliation CAS" $ do
    (qq, matrix) <- mirrorPair pool
    now <- getCurrentTime
    _ <- withDb pool (ingestEnvelope defaultIngestOptions (inbound qq.endpointId now "qq-confirm" "confirm me"))
    [claim] <- startPendingDeliveries pool
    claim.endpointId `shouldBe` matrix.endpointId
    _ <- withDb pool (completeDelivery claim.deliveryId [] (DeliveryAccepted (Just (NativeEventId "native-confirm"))))
    withDb pool (confirmUnconfirmedDelivery claim.deliveryId (NativeEventId "native-confirm"))
      `shouldReturn` True
    withDb pool (listUnconfirmedDeliveries PlatformMatrix 10) `shouldReturn` []

  it "rejects corrupt canonical bodies without changing delivery history" $ do
    (_, matrix) <- mirrorPair pool
    now <- getCurrentTime
    result <- withDb pool (ingestEnvelope defaultIngestOptions (inbound matrix.endpointId now "corrupt-body" "dispatch me"))
    let cid = (resultId result).unCanonicalMessageId
    _ <- withConn pool $ \connection -> execute connection "UPDATE messages SET canonical_content=jsonb_set(canonical_content,'{nodes}','[{\"type\":\"invalid-node\"}]'::jsonb) WHERE canonical_message_id=?" (Only cid)
    withDb pool (loadDispatchMessage (CanonicalMessageId cid)) `shouldThrow` (\case ConversionFailed {} -> True; _ -> False)
    let deliveryStatus = withConn pool $ \connection -> query connection "SELECT status FROM message_deliveries WHERE canonical_message_id=?" (Only cid)
    deliveryBefore <- deliveryStatus :: IO [Only Text]
    deliveryBefore `shouldSatisfy` (not . null)
    [target] <- withDb pool (deliveryTargets (resultId result))
    withDb pool (loadDelivery target.deliveryId) `shouldThrow` (\case ConversionFailed {} -> True; _ -> False)
    deliveryStatus `shouldReturn` deliveryBefore
    _ <- withConn pool $ \connection -> execute connection "UPDATE messages SET canonical_content=jsonb_set(canonical_content,'{nodes}','[]'::jsonb) WHERE canonical_message_id=?" (Only cid)
    repaired <- withDb pool (loadDispatchMessage (CanonicalMessageId cid))
    fmap (.canonicalId) repaired `shouldBe` Just (CanonicalMessageId cid)
    delivery <- withDb pool (loadDelivery target.deliveryId)
    fmap (.canonicalMessageId) delivery `shouldBe` Just (CanonicalMessageId cid)

  it "queues only new live messages and never reconstructs dispatches on restart" $ do
    (_, matrix) <- mirrorPair pool
    now <- getCurrentTime
    ingress <- newIngress =<< newDeliveryQueue (DeliveryId 0)
    let live = inbound matrix.endpointId now "live" "new question"
    first <- withDb pool (ingestEnvelope defaultIngestOptions live)
    duplicate <- withDb pool (ingestEnvelope defaultIngestOptions live)
    backfill <- withDb pool (ingestEnvelope defaultIngestOptions ((inbound matrix.endpointId now "old" "history") {ingestClass = Backfill}))
    suppressed <- withDb pool (ingestEnvelope defaultIngestOptions {createDispatch = False} (inbound matrix.endpointId now "disabled" "history only"))
    mapM_ (queueIngest ingress) [first, duplicate, backfill, suppressed]
    nextIngress ingress `shouldReturn` resultId first
    timeout 10000 (nextIngress ingress) `shouldReturn` Nothing
    restarted <- newIngress =<< newDeliveryQueue (DeliveryId 0)
    timeout 10000 (nextIngress restarted) `shouldReturn` Nothing
    restored <- withDb pool (loadDispatchMessage (resultId first))
    fmap (.canonicalId) restored `shouldBe` Just (resultId first)

  it "closes unfinished receipts on restart without resuming their sends" $ do
    (_, matrix) <- mirrorPair pool
    now <- getCurrentTime
    first <- withDb pool (ingestEnvelope defaultIngestOptions (inbound matrix.endpointId now "interrupted" "two parts"))
    [target] <- withDb pool (deliveryTargets (resultId first))
    Just stored <- withDb pool (loadDelivery target.deliveryId)
    let request = stored {attemptCount = 1}
    withDb pool (startDelivery target.deliveryId 1) `shouldReturn` True
    _ <- withDb pool (planDeliveryParts request ["accepted", "unknown"])
    _ <- withDb pool (beginDeliveryPart request NonIdempotentParts 0)
    _ <- withDb pool (finishDeliveryPart request 0 (AttemptAccepted (Just (NativeEventId "retained"))))
    _ <- withDb pool (beginDeliveryPart request NonIdempotentParts 1)
    unsent <- withDb pool (ingestEnvelope defaultIngestOptions (inbound matrix.endpointId now "not-started" "pending"))
    boundary <- withDb pool deliveryProcessBoundary
    states <- withConn pool $ \connection ->
      query
        connection
        "SELECT status,native_event_id FROM message_delivery_parts WHERE delivery_id=? ORDER BY part_index"
        (Only target.deliveryId.unDeliveryId)
    states `shouldBe` [("accepted_unconfirmed" :: Text, Just ("retained" :: Text)), ("outcome_unknown", Nothing)]
    parents <- withConn pool $ \connection ->
      query
        connection
        "SELECT status FROM message_deliveries WHERE canonical_message_id=ANY(?) AND idempotency_key NOT LIKE 'source:%' ORDER BY delivery_id"
        (Only (PGArray [(resultId first).unCanonicalMessageId, (resultId unsent).unCanonicalMessageId]))
    parents `shouldBe` [Only ("outcome_unknown" :: Text), Only "suppressed"]
    restarted <- newDeliveryQueue boundary
    queueDeliveryRetry restarted target 1
    timeout 10_000 (nextDelivery restarted (const True)) `shouldReturn` Nothing
    Ingested fresh <- withDb pool (ingestEnvelope defaultIngestOptions (inbound matrix.endpointId now "after-restart" "new"))
    queueDeliveries restarted fresh.mirrorDeliveries
    next <- nextDelivery restarted (const True)
    map (.deliveryId) fresh.mirrorDeliveries `shouldBe` [next.target.deliveryId]
    withDb pool (loadDispatchMessage (resultId first)) >>= ((`shouldBe` Just (resultId first)) . fmap (.canonicalId))

  it "maps every wire part echo and reply without prematurely settling the parent" $ do
    (qq, matrix) <- mirrorPair pool
    now <- getCurrentTime
    original <- withDb pool (ingestEnvelope defaultIngestOptions (inbound matrix.endpointId now "split-original" "onetwo"))
    [claim] <- startPendingDeliveries pool
    withDb pool (planDeliveryParts claim ["one", "two"]) `shouldReturn` True
    withDb pool (beginDeliveryPart claim NonIdempotentParts 0) `shouldReturn` PartSend
    withDb pool (finishDeliveryPart claim 0 (AttemptAccepted (Just (NativeEventId "part-one")))) `shouldReturn` True
    let echo native text = (inbound qq.endpointId now native text) {senderNativeId = NativeUserId "9"}
    withDb pool (ingestEnvelope defaultIngestOptions (echo "part-one" "one")) `shouldReturn` DeliveryEcho (resultId original)
    withDb pool (beginDeliveryPart claim NonIdempotentParts 1) `shouldReturn` PartSend
    withDb pool (finishDeliveryPart claim 1 (AttemptAccepted (Just (NativeEventId "part-two")))) `shouldReturn` True
    -- A reply may arrive before the platform echoes the part.
    reply <- withDb pool (ingestEnvelope defaultIngestOptions ((inbound qq.endpointId now "reply-second" "question") {relations = [ReplyTo (NativeEventId "part-two")]}))
    linked <- withConn pool $ \conn -> query conn "SELECT target_canonical_message_id FROM message_relations WHERE canonical_message_id=? AND relation_kind='reply'" (Only (resultId reply).unCanonicalMessageId)
    (linked :: [Only Int64]) `shouldBe` [Only (resultId original).unCanonicalMessageId]
    withDb pool (completeDelivery claim.deliveryId [] (DeliveryAccepted (Just (NativeEventId "part-one")))) `shouldReturn` True
    withDb pool (ingestEnvelope defaultIngestOptions (echo "part-two" "two")) `shouldReturn` DeliveryEcho (resultId original)
    states <- withConn pool $ \conn -> query conn "SELECT status FROM message_deliveries WHERE delivery_id=?" (Only claim.deliveryId.unDeliveryId)
    (states :: [Only Text]) `shouldBe` [Only "confirmed"]
    followup <- withDb pool (enqueueOutbound (OutboundDraft 42 "chat" Nothing (Body [NText "followup"]) (Just (resultId original).unCanonicalMessageId) Nothing Nothing))
    _ <- withConn pool $ \conn -> execute conn "UPDATE message_relations SET target_native_event_id='part-two' WHERE canonical_message_id=? AND relation_kind='reply'" (Only followup.canonicalMessageId.unCanonicalMessageId)
    -- Make a different chunk the newest echo: explicit part identity wins.
    _ <- withConn pool $ \conn -> execute conn "UPDATE platform_events SET occurred_at=now()+interval '1 minute' WHERE native_event_id='part-one'" ()
    Just quotedPart <- withDb pool (loadDelivery followup.primaryDeliveryId)
    (quotedPart.replyContext >>= (.nativeId)) `shouldBe` Just (NativeEventId "part-two")

  it "reconciles provider status per part and retries only an explicitly failed part" $ do
    (_, matrix) <- mirrorPair pool
    now <- getCurrentTime
    _ <- withDb pool (ingestEnvelope defaultIngestOptions (inbound matrix.endpointId now "status-original" "onetwo"))
    [claim] <- startPendingDeliveries pool
    _ <- withDb pool (planDeliveryParts claim ["one", "two"])
    forM_ [(0, "one"), (1, "two")] $ \(index, native) -> do
      _ <- withDb pool (beginDeliveryPart claim NonIdempotentParts index)
      _ <- withDb pool (finishDeliveryPart claim index (AttemptAccepted (Just (NativeEventId native))))
      pure ()
    _ <- withDb pool (completeDelivery claim.deliveryId [] (DeliveryAccepted (Just (NativeEventId "one"))))
    unconfirmedParts <- withDb pool (listUnconfirmedDeliveries PlatformQQ 10)
    length unconfirmedParts `shouldBe` 2
    withDb pool (confirmUnconfirmedDelivery claim.deliveryId (NativeEventId "one")) `shouldReturn` True
    remaining <- withDb pool (listUnconfirmedDeliveries PlatformQQ 10)
    map (.nativeEventId) remaining `shouldBe` [NativeEventId "two"]
    withDb pool (retryUnconfirmedDelivery claim.deliveryId (NativeEventId "two") "provider explicitly failed") `shouldReturn` True
    [retry] <- startPendingDeliveries pool
    withDb pool (beginDeliveryPart retry NonIdempotentParts 0)
      `shouldReturn` PartRecorded (AttemptConfirmed (Just (NativeEventId "one")))
    withDb pool (beginDeliveryPart retry NonIdempotentParts 1) `shouldReturn` PartSend

  it "keeps a second proven part failure that arrives during the first retry" $ do
    (_, matrix) <- mirrorPair pool
    now <- getCurrentTime
    _ <- withDb pool (ingestEnvelope defaultIngestOptions (inbound matrix.endpointId now "status-race" "two parts"))
    [request] <- startPendingDeliveries pool
    _ <- withDb pool (planDeliveryParts request ["first", "second"])
    forM_ [(0, "first"), (1, "second")] $ \(index, native) -> do
      _ <- withDb pool (beginDeliveryPart request NonIdempotentParts index)
      _ <- withDb pool (finishDeliveryPart request index (AttemptAccepted (Just (NativeEventId native))))
      pure ()
    _ <- withDb pool (completeDelivery request.deliveryId [] (DeliveryAccepted (Just (NativeEventId "first"))))
    withDb pool (retryUnconfirmedDelivery request.deliveryId (NativeEventId "first") "failed first") `shouldReturn` True
    [retried] <- startPendingDeliveries pool
    withDb pool (retryUnconfirmedDelivery request.deliveryId (NativeEventId "second") "failed second") `shouldReturn` True
    _ <- withDb pool (beginDeliveryPart retried NonIdempotentParts 0)
    _ <- withDb pool (finishDeliveryPart retried 0 (AttemptAccepted (Just (NativeEventId "replacement"))))
    _ <- withDb pool (completeDelivery request.deliveryId [] (DeliveryAccepted (Just (NativeEventId "replacement"))))
    [again] <- startPendingDeliveries pool
    withDb pool (beginDeliveryPart again NonIdempotentParts 0) `shouldReturn` PartRecorded (AttemptAccepted (Just (NativeEventId "replacement")))
    withDb pool (beginDeliveryPart again NonIdempotentParts 1) `shouldReturn` PartSend

  it "resumes only the remaining wire part and rejects a changed retry plan" $ do
    (_, matrix) <- mirrorPair pool
    now <- getCurrentTime
    _ <- withDb pool (ingestEnvelope defaultIngestOptions (inbound matrix.endpointId now "retry-original" "onetwo"))
    [claim] <- startPendingDeliveries pool
    withDb pool (planDeliveryParts claim ["one", "two"]) `shouldReturn` True
    _ <- withDb pool (beginDeliveryPart claim IdempotentParts 0)
    _ <- withDb pool (finishDeliveryPart claim 0 (AttemptConfirmed (Just (NativeEventId "one"))))
    _ <- withDb pool (beginDeliveryPart claim IdempotentParts 1)
    _ <- withDb pool (finishDeliveryPart claim 1 (AttemptRetryable "503"))
    _ <- withDb pool (completeDelivery claim.deliveryId [] (DeliveryRetry "503" now))
    [retry] <- startPendingDeliveries pool
    withDb pool (planDeliveryParts retry ["changed"]) `shouldReturn` False
    withDb pool (planDeliveryParts retry ["one", "two"]) `shouldReturn` True
    withDb pool (beginDeliveryPart retry IdempotentParts 0)
      `shouldReturn` PartRecorded (AttemptConfirmed (Just (NativeEventId "one")))
    withDb pool (beginDeliveryPart retry IdempotentParts 1) `shouldReturn` PartSend
    withDb pool (finishDeliveryPart claim 1 (AttemptConfirmed (Just (NativeEventId "stale")))) `shouldReturn` False

  it "rechecks the iMessage source after a failed page without restarting the worker" $ do
    let health source = object ["source_fingerprint" .= (source :: Text)]
        chats = object ["chats" .= [object ["id" .= (1 :: Int), "guid" .= ("test-chat" :: Text)]]]
        page cursor more = object ["next_rowid" .= (cursor :: Int), "has_more" .= more]
    responses <- newIORef [health "old", health "old", chats, page 100 True, page 5 False, health "new", chats, page 5 False]
    requests <- newIORef []
    caughtUp <- newEmptyMVar
    let bridge req respond = do
          body <- Wai.strictRequestBody req
          forM_ (decode body) $ \request -> modifyIORef' requests (<> [request])
          payload <- atomicModifyIORef' responses $ \case
            [] -> ([], Nothing)
            value : rest -> (rest, Just value)
          case payload of
            Just value -> respond (Wai.responseLBS status200 [] (encode value))
            Nothing -> do
              void (tryPutMVar caughtUp ())
              respond (Wai.responseLBS status503 [] "{}")
    Warp.testWithApplication (pure bridge) $ \port -> do
      runtime <- newHttpRuntime
      deliveries <- newDeliveryQueue =<< withDb pool deliveryProcessBoundary
      ingress <- newIngress deliveries
      let cfg = IMessageConfig ("http://127.0.0.1:" <> T.pack (show port)) "test-only" "test-account" "test-chat" [] "Max" Nothing 10_000
      withAsync (withDbLog pool (iMessageWorker runtime cfg Nothing ingress deliveries)) $ \task -> do
        link task
        timeout 5_000_000 (takeMVar caughtUp) `shouldReturn` Just ()
        rows <- withConn pool $ \conn -> query conn "SELECT cursor,source_fingerprint FROM platform_ingest_cursors" ()
        (rows :: [(Value, Text)]) `shouldBe` [(Number 5, "new")]
        sent <- readIORef requests
        let cursors =
              [ KeyMap.lookup "since_rowid" params
              | Object request <- sent,
                KeyMap.lookup "method" request == Just (String "messages.after"),
                Just (Object params) <- [KeyMap.lookup "params" request]
              ]
        cursors `shouldBe` map (Just . Number) [0, 100, 0]

  it "retries a Matrix second-part 503 with the same transaction and without resending the first" $ do
    (qq, _) <- mirrorPair pool
    now <- getCurrentTime
    _ <- withDb pool (ingestEnvelope defaultIngestOptions (inbound qq.endpointId now "matrix-retry" "onetwo"))
    [claim] <- startPendingDeliveries pool
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
        journal current =
          PartJournal
            { plan = withDb pool . planDeliveryParts current,
              begin = \safety index -> withDb pool (beginDeliveryPart current safety index),
              finish = \index result -> withDb pool (finishDeliveryPart current index result)
            }
        operation = DeliverMessage (LoweredMessage Nothing [[NText "one"], [NText "two"]] [])
    first <- transport.deliver (journal claim) claim operation
    case first of
      AttemptRetryable _ -> pure ()
      other -> expectationFailure (show other)
    _ <- withDb pool (completeDelivery claim.deliveryId [] (DeliveryRetry "503" now))
    [retry] <- startPendingDeliveries pool
    transport.deliver (journal retry) retry operation
      `shouldReturn` AttemptConfirmed (Just (NativeEventId "$one"))
    readIORef count `shouldReturn` 3
    keys <- withConn pool $ \conn -> query conn "SELECT idempotency_key,status FROM message_delivery_parts WHERE delivery_id=? ORDER BY part_index" (Only claim.deliveryId.unDeliveryId)
    (keys :: [(Text, Text)]) `shouldBe` [(claim.idempotencyKey <> "-0", "confirmed"), (claim.idempotencyKey <> "-1", "confirmed")]

  it "emits a canonical QQ file through the part journal and removes edge staging" $ do
    (_, matrix) <- mirrorPair pool
    now <- getCurrentTime
    _ <- withDb pool (ingestEnvelope defaultIngestOptions (inbound matrix.endpointId now "file-original" "file"))
    [claim] <- startPendingDeliveries pool
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
            { plan = withDb pool . planDeliveryParts claim,
              begin = \safety index -> withDb pool (beginDeliveryPart claim safety index),
              finish = \index result -> withDb pool (finishDeliveryPart claim index result)
            }
    manager <- HTTP.newManager HTTP.defaultManagerSettings
    let transport = oneBotDeliveryTransport (httpRuntimeFromManagers manager manager manager) PlatformQQ backend
        meta = MediaMeta MFile Nothing (Just 7) (Just "report.csv") Nothing Nothing
    transport.deliver journal claim (DeliverMessage (LoweredMessage Nothing [[NMedia (ResolvedBytes "a,b\n1,2") meta]] []))
      `shouldReturn` AttemptAccepted Nothing
    paths <- readIORef staged
    length paths `shouldBe` 1
    mapM doesFileExist paths `shouldReturn` [False]

  it "turns a unique self echo into delivery confirmation, not a second message" $ do
    (qq, matrix) <- mirrorPair pool
    now <- getCurrentTime
    original <- withDb pool (ingestEnvelope defaultIngestOptions (inbound matrix.endpointId now "mx-relay" "same body"))
    [claim] <- startPendingDeliveries pool
    _ <- withDb pool (completeDelivery claim.deliveryId [] (DeliveryUnknown "response lost" now))
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
    length queued.deliveries `shouldBe` 2
    claims <- startPendingDeliveries pool
    fmap (.endpointId) claims `shouldMatchList` [qq.endpointId, matrix.endpointId]
    ledger <- withConn pool $ \conn ->
      query
        conn
        "SELECT m.message_origin, count(pe.platform_event_id), count(d.delivery_id) \
        \ FROM messages m \
        \ LEFT JOIN platform_events pe USING (canonical_message_id) \
        \ LEFT JOIN message_deliveries d USING (canonical_message_id) \
        \ WHERE m.canonical_message_id = ? \
        \ GROUP BY m.message_origin"
        (Only queued.canonicalMessageId.unCanonicalMessageId)
    (ledger :: [(Text, Int64, Int64)]) `shouldBe` [("outbound", 0, 2)]

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
    claims <- startPendingDeliveries pool
    fmap (\delivery -> delivery.replyContext >>= (.nativeId)) claims
      `shouldBe` [Just (NativeEventId "matrix-target")]

  it "fans edit, reaction, and redaction through capable native copies" $ do
    (qq, matrix) <- mirrorPair pool
    now <- getCurrentTime
    metaTarget <-
      withDb pool $
        ingestEnvelope defaultIngestOptions (inbound qq.endpointId now "qq-meta-target" "before")
    [targetCopy] <- startPendingDeliveries pool
    targetCopy.endpointId `shouldBe` matrix.endpointId
    withDb
      pool
      (completeDelivery targetCopy.deliveryId [] (DeliveryConfirmedAs (Just (NativeEventId "matrix-meta-target"))))
      `shouldReturn` True

    let editEnvelope =
          (inboundBody qq.endpointId (addUTCTime 1 now) "qq-edit" (Body [NText "after"]))
            { eventKind = EventEdit,
              relations = [Replaces (NativeEventId "qq-meta-target")]
            }
    edit <- withDb pool (ingestEnvelope defaultIngestOptions editEnvelope)
    case edit of
      Ingested fresh -> length fresh.mirrorDeliveries `shouldBe` 1
      other -> expectationFailure ("expected new edit: " <> show other)
    [editClaim] <- startPendingDeliveries pool
    editClaim.eventKind `shouldBe` EventEdit
    editClaim.endpointId `shouldBe` matrix.endpointId
    editClaim.actionTarget `shouldBe` Just (NativeEventId "matrix-meta-target")
    editClaim.body `shouldBe` Body [NText "after"]
    withDb pool (completeDelivery editClaim.deliveryId [] (DeliveryConfirmedAs (Just (NativeEventId "matrix-edit"))))
      `shouldReturn` True

    let reactionEnvelope =
          (inboundBody matrix.endpointId (addUTCTime 2 now) "matrix-reaction" (Body []))
            { eventKind = EventReaction,
              relations = [ReactsTo (NativeEventId "matrix-meta-target") "212" ReactionAdd]
            }
    reaction <- withDb pool (ingestEnvelope defaultIngestOptions reactionEnvelope)
    case reaction of
      Ingested fresh -> length fresh.mirrorDeliveries `shouldBe` 1
      other -> expectationFailure ("expected new reaction: " <> show other)
    [reactionClaim] <- startPendingDeliveries pool
    reactionClaim.eventKind `shouldBe` EventReaction
    reactionClaim.endpointId `shouldBe` qq.endpointId
    reactionClaim.actionTarget `shouldBe` Just (NativeEventId "qq-meta-target")
    reactionClaim.reactionKey `shouldBe` Just "212"
    reactionClaim.reactionAction `shouldBe` ReactionAdd
    withDb pool (completeDelivery reactionClaim.deliveryId [] (DeliveryConfirmedAs Nothing))
      `shouldReturn` True

    let redactionEnvelope =
          (inboundBody qq.endpointId (addUTCTime 3 now) "qq-redaction" (Body []))
            { eventKind = EventRedaction,
              relations = [Redacts (NativeEventId "qq-meta-target")]
            }
    redaction <- withDb pool (ingestEnvelope defaultIngestOptions redactionEnvelope)
    case redaction of
      Ingested fresh -> length fresh.mirrorDeliveries `shouldBe` 1
      other -> expectationFailure ("expected new redaction: " <> show other)
    [redactionClaim] <- startPendingDeliveries pool
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
    [targetCopy] <- startPendingDeliveries pool
    withDb
      pool
      (completeDelivery targetCopy.deliveryId [] (DeliveryConfirmedAs (Just (NativeEventId "matrix-meta-malformed-target"))))
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
      Ingested fresh -> length fresh.mirrorDeliveries `shouldBe` 0
      other -> expectationFailure ("expected new edit: " <> show other)
    startPendingDeliveries pool `shouldReturn` []

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
    length queued.deliveries `shouldBe` 1
    Just duplicate <- withDb pool (enqueueReaction draft)
    duplicate.canonicalMessageId `shouldBe` queued.canonicalMessageId
    duplicate.deliveries `shouldBe` []
    [claim] <- startPendingDeliveries pool
    claim.eventKind `shouldBe` EventReaction
    claim.endpointId `shouldBe` qq.endpointId
    claim.actionTarget `shouldBe` Just (NativeEventId "qq-reaction-target")
    withDb pool (completeDelivery claim.deliveryId [] (DeliveryConfirmedAs Nothing))
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
    length queued.deliveries `shouldBe` 1
    claims <- startPendingDeliveries pool
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
    [claim] <- startPendingDeliveries pool
    withDb pool (completeDelivery claim.deliveryId [] (DeliveryAccepted Nothing))
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

-- | Select fixture receipts for store tests. Runtime ordering, ownership and
-- retry scheduling are exercised by the process queue tests.
startPendingDeliveries :: DbPool -> IO [DeliveryRequest]
startPendingDeliveries pool = do
  identifiers <- withConn pool $ \connection ->
    query
      connection
      "SELECT DISTINCT ON (endpoint_id) delivery_id FROM message_deliveries WHERE status IN ('pending','failed') AND next_attempt_at <= now() ORDER BY endpoint_id,delivery_id"
      ()
  forM identifiers $ \(Only identifier) -> do
    Just stored <- withDb pool (loadDelivery (DeliveryId identifier))
    let request = stored {attemptCount = stored.attemptCount + 1}
    withDb pool (startDelivery request.deliveryId request.attemptCount) `shouldReturn` True
    pure request

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

ledgerCounts :: DbPool -> EndpointId -> EndpointId -> IO (Int64, Int64, Int64, Int64)
ledgerCounts pool (EndpointId source) (EndpointId target) = withConn pool $ \conn -> do
  rows <-
    query
      conn
      "SELECT \
      \ (SELECT count(*) FROM messages), \
      \ (SELECT count(*) FROM platform_events), \
      \ (SELECT count(*) FROM message_deliveries WHERE endpoint_id = ? AND status = 'confirmed'), \
      \ (SELECT count(*) FROM message_deliveries WHERE endpoint_id = ? AND status = 'pending')"
      (source, target)
  case rows of
    [counts] -> pure counts
    _ -> error "ledgerCounts: expected one row"
