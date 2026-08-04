module Max.PlatformStoreSpec (spec) where

import Control.Concurrent.Async (concurrently)
import Data.Aeson (Value (..), object, toJSON, (.=))
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime, addUTCTime, getCurrentTime)
import Database.PostgreSQL.Simple (Only (..), execute, query)
import Helpers (truncateAll, withDb)
import Max.DB.Connection (DbPool, withConn)
import Max.IR
import Max.IR.Lower
import Max.Platform.Envelope (InboundEnvelope (..))
import Max.Platform.Store
import Max.Platform.Store qualified as PlatformStore
import Max.Platform.Types
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
    claims <- withDb pool (claimDeliveries "mirror-cutover" 10 30)
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
    claims <- withDb pool (claimDeliveries "mirror-cutover" 10 30)
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
    [claim] <- withDb pool (claimDeliveries "worker-a" 10 30)
    claim.endpointId `shouldBe` qq.endpointId
    _ <- withDb pool (completeDelivery "worker-a" claim.deliveryId [] (DeliveryUnknown "timeout" now))
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
    claims <- withDb pool (claimDeliveries "worker-a" 10 30)
    claims `shouldSatisfy` \case
      [claim] -> claim.endpointId == qq.endpointId && claim.attemptCount == 1
      _ -> False
    again <- withDb pool (claimDeliveries "worker-b" 10 30)
    again `shouldBe` []
    claim <- case claims of
      [onlyClaim] -> pure onlyClaim
      _ -> expectationFailure "expected one leased delivery" >> fail "unreachable"
    stolen <-
      withDb pool $
        completeDelivery
          "worker-b"
          claim.deliveryId
          []
          (DeliveryConfirmedAs (Just (NativeEventId "qq-echo")))
    stolen `shouldBe` False
    completed <-
      withDb pool $
        completeDelivery
          "worker-a"
          claim.deliveryId
          []
          (DeliveryConfirmedAs (Just (NativeEventId "qq-echo")))
    completed `shouldBe` True

  it "quarantines an expired sending lease without retrying it or blocking the endpoint" $ do
    (qq, matrix) <- mirrorPair pool
    now <- getCurrentTime
    _ <- withDb pool (ingestEnvelope defaultIngestOptions (inbound matrix.endpointId now "mx-expired-1" "maybe sent"))
    _ <- withDb pool (ingestEnvelope defaultIngestOptions (inbound matrix.endpointId (addUTCTime 1 now) "mx-expired-2" "send after it"))
    [abandoned] <- withDb pool (claimDeliveries "worker-gone" 10 30)
    abandoned.endpointId `shouldBe` qq.endpointId
    _ <- withConn pool $ \conn ->
      execute
        conn
        "UPDATE message_deliveries SET lease_expires_at = now() - interval '1 second' WHERE delivery_id = ?"
        (Only abandoned.deliveryId.unDeliveryId)

    [next] <- withDb pool (claimDeliveries "worker-next" 10 30)
    next.endpointId `shouldBe` qq.endpointId
    next.body `shouldBe` Body [NText "send after it"]
    next.deliveryId `shouldNotBe` abandoned.deliveryId
    withDb pool
      (completeDelivery "worker-gone" abandoned.deliveryId [] (DeliveryConfirmedAs (Just (NativeEventId "late-receipt"))))
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

  it "persists the shared lowerer's degradation audit on completion" $ do
    (qq, matrix) <- mirrorPair pool
    now <- getCurrentTime
    _ <- withDb pool (ingestEnvelope defaultIngestOptions (inbound matrix.endpointId now "mx-lower-notes" "hello"))
    [claim] <- withDb pool (claimDeliveries "worker-a" 10 30)
    let notes = [LowerNote "mention" NoteFolded (Just "no identity on endpoint")]
    withDb pool (completeDelivery "worker-a" claim.deliveryId notes (DeliveryConfirmedAs Nothing))
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
    firstClaims <- withDb pool (claimDeliveries "worker-a" 10 30)
    firstClaims `shouldSatisfy` \case
      [claim] -> claim.endpointId == qq.endpointId && claim.body == Body [NText "first"]
      _ -> False
    case firstClaims of
      [firstClaim] -> do
        withDb pool (completeDelivery "worker-a" firstClaim.deliveryId [] (DeliveryAccepted (Just (NativeEventId "reused-native"))))
          `shouldReturn` True
        secondClaims <- withDb pool (claimDeliveries "worker-a" 10 30)
        secondClaims `shouldSatisfy` \case
          [claim] -> claim.endpointId == qq.endpointId && claim.body == Body [NText "second"]
          _ -> False
        secondClaim <- case secondClaims of
          [claim] -> pure claim
          _ -> expectationFailure "expected the second ordered delivery" >> fail "unreachable"
        withDb pool (completeDelivery "worker-a" secondClaim.deliveryId [] (DeliveryAccepted (Just (NativeEventId "reused-native"))))
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
    [claim] <- withDb pool (claimDeliveries "worker-a" 10 30)
    claim.endpointId `shouldBe` qq.endpointId
    unknown <-
      withDb pool $
        completeDelivery "worker-a" claim.deliveryId [] (DeliveryUnknown "timeout after write" (addUTCTime (-1) now))
    unknown `shouldBe` True
    withDb pool (claimDeliveries "worker-b" 10 30) `shouldReturn` []

  it "requeues an accepted send only after explicit provider failure evidence" $ do
    (qq, matrix) <- mirrorPair pool
    now <- getCurrentTime
    _ <- withDb pool (ingestEnvelope defaultIngestOptions (inbound qq.endpointId now "qq-reconcile" "status me"))
    [claim] <- withDb pool (claimDeliveries "worker-a" 10 30)
    claim.endpointId `shouldBe` matrix.endpointId
    accepted <-
      withDb pool $
        completeDelivery "worker-a" claim.deliveryId [] (DeliveryAccepted (Just (NativeEventId "native-out")))
    accepted `shouldBe` True
    withDb pool (claimDeliveries "worker-b" 10 30) `shouldReturn` []
    unconfirmed <- withDb pool (listUnconfirmedDeliveries PlatformMatrix 10)
    fmap (.deliveryId) unconfirmed `shouldBe` [claim.deliveryId]
    withDb pool (confirmUnconfirmedDelivery claim.deliveryId (NativeEventId "wrong")) `shouldReturn` False
    withDb pool (retryUnconfirmedDelivery claim.deliveryId (NativeEventId "native-out") "provider failed")
      `shouldReturn` True
    retried <- withDb pool (claimDeliveries "worker-b" 10 30)
    fmap (.deliveryId) retried `shouldBe` [claim.deliveryId]

  it "confirms an accepted send through a status reconciliation CAS" $ do
    (qq, matrix) <- mirrorPair pool
    now <- getCurrentTime
    _ <- withDb pool (ingestEnvelope defaultIngestOptions (inbound qq.endpointId now "qq-confirm" "confirm me"))
    [claim] <- withDb pool (claimDeliveries "worker-a" 10 30)
    claim.endpointId `shouldBe` matrix.endpointId
    _ <- withDb pool (completeDelivery "worker-a" claim.deliveryId [] (DeliveryAccepted (Just (NativeEventId "native-confirm"))))
    withDb pool (confirmUnconfirmedDelivery claim.deliveryId (NativeEventId "native-confirm"))
      `shouldReturn` True
    withDb pool (listUnconfirmedDeliveries PlatformMatrix 10) `shouldReturn` []

  it "leases dispatch eligibility once and recovers only after its lease" $ do
    (_, matrix) <- mirrorPair pool
    now <- getCurrentTime
    result <- withDb pool (ingestEnvelope defaultIngestOptions (inbound matrix.endpointId now "mx-dispatch" "dispatch me"))
    let cid = resultId result
    first <- withDb pool (claimDispatch "runtime-a" cid 30)
    fmap (.canonicalMessageId) first `shouldBe` Just cid
    withDb pool (claimDispatch "runtime-b" cid 30) `shouldReturn` Nothing
    case first of
      Nothing -> expectationFailure "expected dispatch claim"
      Just _ -> do
        completed <- withDb pool (completeDispatch "runtime-a" cid DispatchCompleted)
        completed `shouldBe` True
        withDb pool (claimDispatch "runtime-b" cid 30) `shouldReturn` Nothing

  it "turns a unique self echo into delivery confirmation, not a second message" $ do
    (qq, matrix) <- mirrorPair pool
    now <- getCurrentTime
    original <- withDb pool (ingestEnvelope defaultIngestOptions (inbound matrix.endpointId now "mx-relay" "same body"))
    [claim] <- withDb pool (claimDeliveries "worker-a" 10 30)
    _ <- withDb pool (completeDelivery "worker-a" claim.deliveryId [] (DeliveryUnknown "response lost" now))
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
              sourceCompatibilityMessageId = Nothing,
              canonicalBody = Body [NText "hello both sides"],
              replyToCompatibilityMessageId = Nothing
            }
    queued.deliveriesCreated `shouldBe` 2
    claims <- withDb pool (claimDeliveries "delivery-worker" 10 30)
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
    [(legacyGroup, targetMessage)] <-
      withConn pool $ \conn ->
        query
          conn
          "SELECT group_id, message_id FROM messages WHERE canonical_message_id = ?"
          (Only (resultId target).unCanonicalMessageId)
    queued <-
      withDb pool $
        enqueueOutbound
          OutboundDraft
            { legacyConversationId = legacyGroup,
              transcriptKind = "chat",
              sourceCompatibilityMessageId = Nothing,
              canonicalBody = Body [NText "reply"],
              replyToCompatibilityMessageId = Just targetMessage
            }
    relations <- withConn pool $ \conn ->
      query
        conn
        "SELECT target_canonical_message_id FROM message_relations WHERE canonical_message_id = ? AND relation_kind = 'reply'"
        (Only queued.canonicalMessageId.unCanonicalMessageId)
    (relations :: [Only Int64]) `shouldBe` [Only (resultId target).unCanonicalMessageId]
    claims <- withDb pool (claimDeliveries "native-reply" 10 30)
    fmap (\delivery -> delivery.replyContext >>= (.nativeId)) claims
      `shouldBe` [Just (NativeEventId "matrix-target")]

  it "fans edit, reaction, and redaction through capable native copies" $ do
    (qq, matrix) <- mirrorPair pool
    now <- getCurrentTime
    _ <-
      withDb pool $
        ingestEnvelope defaultIngestOptions (inbound qq.endpointId now "qq-meta-target" "before")
    [targetCopy] <- withDb pool (claimDeliveries "meta-target" 10 30)
    targetCopy.endpointId `shouldBe` matrix.endpointId
    withDb pool
      (completeDelivery "meta-target" targetCopy.deliveryId [] (DeliveryConfirmedAs (Just (NativeEventId "matrix-meta-target"))))
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
    [editClaim] <- withDb pool (claimDeliveries "meta-edit" 10 30)
    editClaim.eventKind `shouldBe` EventEdit
    editClaim.endpointId `shouldBe` matrix.endpointId
    editClaim.actionTarget `shouldBe` Just (NativeEventId "matrix-meta-target")
    editClaim.body `shouldBe` Body [NText "after"]
    withDb pool (completeDelivery "meta-edit" editClaim.deliveryId [] (DeliveryConfirmedAs (Just (NativeEventId "matrix-edit"))))
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
    [reactionClaim] <- withDb pool (claimDeliveries "meta-reaction" 10 30)
    reactionClaim.eventKind `shouldBe` EventReaction
    reactionClaim.endpointId `shouldBe` qq.endpointId
    reactionClaim.actionTarget `shouldBe` Just (NativeEventId "qq-meta-target")
    reactionClaim.reactionKey `shouldBe` Just "212"
    reactionClaim.reactionAction `shouldBe` ReactionAdd
    withDb pool (completeDelivery "meta-reaction" reactionClaim.deliveryId [] (DeliveryConfirmedAs Nothing))
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
    [redactionClaim] <- withDb pool (claimDeliveries "meta-redaction" 10 30)
    redactionClaim.eventKind `shouldBe` EventRedaction
    redactionClaim.endpointId `shouldBe` matrix.endpointId
    redactionClaim.actionTarget `shouldBe` Just (NativeEventId "matrix-meta-target")

  it "uses the total capability decoder for meta fan-out" $ do
    (qq, matrix) <- mirrorPair pool
    now <- getCurrentTime
    _ <-
      withDb pool $
        ingestEnvelope defaultIngestOptions (inbound qq.endpointId now "qq-meta-malformed-target" "before")
    [targetCopy] <- withDb pool (claimDeliveries "meta-malformed-target" 10 30)
    withDb pool
      (completeDelivery "meta-malformed-target" targetCopy.deliveryId [] (DeliveryConfirmedAs (Just (NativeEventId "matrix-meta-malformed-target"))))
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
    withDb pool (claimDeliveries "meta-malformed-edit" 10 30) `shouldReturn` []

  it "publishes bot QQ reactions idempotently and reconciles their notice echo" $ do
    (qq, _) <- mirrorPair pool
    now <- getCurrentTime
    target <-
      withDb pool $
        ingestEnvelope
          defaultIngestOptions {createMirrorDeliveries = False}
          (inbound qq.endpointId now "qq-reaction-target" "target")
    [Only targetMessage] <- withConn pool $ \conn ->
      query
        conn
        "SELECT message_id FROM messages WHERE canonical_message_id = ?"
        (Only (resultId target).unCanonicalMessageId)
    caps <- withDb pool (conversationAdvertisedCaps 42 (Just targetMessage))
    caps.canReaction `shouldBe` True
    missingCaps <- withDb pool (conversationAdvertisedCaps 42 (Just 999999999))
    missingCaps.canReaction `shouldBe` False
    let draft =
          ReactionDraft
            { legacyConversationId = 42,
              targetCompatibilityMessageId = targetMessage,
              reactionKey = "212",
              reactionAction = ReactionAdd,
              requiredPlatform = Just PlatformQQ
            }
    Just queued <- withDb pool (enqueueReaction draft)
    queued.deliveriesCreated `shouldBe` 1
    withDb pool (enqueueReaction draft) `shouldReturn` Just queued
    [claim] <- withDb pool (claimDeliveries "bot-reaction" 10 30)
    claim.eventKind `shouldBe` EventReaction
    claim.endpointId `shouldBe` qq.endpointId
    claim.actionTarget `shouldBe` Just (NativeEventId "qq-reaction-target")
    withDb pool (completeDelivery "bot-reaction" claim.deliveryId [] (DeliveryConfirmedAs Nothing))
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
    [Only targetMessage] <- withConn pool $ \conn ->
      query
        conn
        "SELECT message_id FROM messages WHERE canonical_message_id = ?"
        (Only (resultId target).unCanonicalMessageId)
    _ <- withConn pool $ \conn ->
      execute
        conn
        "UPDATE conversation_endpoints SET capabilities = '\"malformed\"'::jsonb WHERE endpoint_id = ?"
        (Only qq.endpointId.unEndpointId)
    let draft =
          ReactionDraft
            { legacyConversationId = 42,
              targetCompatibilityMessageId = targetMessage,
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
    sourceRows <- withConn pool $ \conn ->
      query conn "SELECT message_id FROM messages WHERE canonical_message_id = ?" (Only (resultId source).unCanonicalMessageId)
    sourceMessage <- case sourceRows :: [Only Int64] of
      [Only message] -> pure message
      _ -> expectationFailure "missing source compatibility message" >> fail "unreachable"
    queued <-
      withDb pool $
        enqueueOutbound
          OutboundDraft
            { legacyConversationId = 42,
              transcriptKind = "command",
              sourceCompatibilityMessageId = Just sourceMessage,
              canonicalBody = Body [NText "status"],
              replyToCompatibilityMessageId = Nothing
            }
    queued.deliveriesCreated `shouldBe` 1
    claims <- withDb pool (claimDeliveries "local-command" 10 30)
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
        \       pi.native_user_id \
        \ FROM messages m \
        \ JOIN principal_identities pi \
        \   ON pi.principal_identity_id = (m.canonical_content->'nodes'->0->>'identity')::bigint \
        \ WHERE m.canonical_message_id = ?"
        (Only (resultId result).unCanonicalMessageId)
    (rows :: [(Text, Text, Text)])
      `shouldBe` [("[@#2291939848]  hello", "2291939848", "2291939848")]

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
      content = body,
      relations = [],
      sourceCursor = Just (PlatformCursor (String "next")),
      rawPayload = Just (object ["event_id" .= eventId])
    }

resultId :: IngestResult -> CanonicalMessageId
resultId = \case
  Ingested result -> result.canonicalMessageId
  AlreadyIngested cid -> cid
  DeliveryEcho cid -> cid

isNew :: IngestResult -> Bool
isNew (Ingested _) = True
isNew _ = False

isDuplicate :: IngestResult -> Bool
isDuplicate (AlreadyIngested _) = True
isDuplicate _ = False

tuple8ToList :: (a, a, a, a, a, a, a, a) -> [a]
tuple8ToList (a, b, c, d, e, f, g, h) = [a, b, c, d, e, f, g, h]

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
