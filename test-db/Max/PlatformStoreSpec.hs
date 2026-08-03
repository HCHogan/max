module Max.PlatformStoreSpec (spec) where

import Control.Concurrent.Async (concurrently)
import Data.Aeson (Value (..), object, (.=))
import Data.Int (Int64)
import Data.Text (Text)
import Data.Time (UTCTime, addUTCTime, getCurrentTime)
import Database.PostgreSQL.Simple (Only (..), query)
import Helpers (truncateAll, withDb)
import Max.DB.Connection (DbPool, withConn)
import Max.Platform.Store
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
    _ <- withDb pool (completeDelivery "worker-a" claim.deliveryId (DeliveryUnknown "timeout" now))
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
          (DeliveryConfirmedAs (Just (NativeEventId "qq-echo")))
    stolen `shouldBe` False
    completed <-
      withDb pool $
        completeDelivery
          "worker-a"
          claim.deliveryId
          (DeliveryConfirmedAs (Just (NativeEventId "qq-echo")))
    completed `shouldBe` True

  it "never automatically retries an outcome-unknown non-idempotent delivery" $ do
    (qq, matrix) <- mirrorPair pool
    now <- getCurrentTime
    _ <- withDb pool (ingestEnvelope defaultIngestOptions (inbound matrix.endpointId now "mx-unknown" "maybe sent"))
    [claim] <- withDb pool (claimDeliveries "worker-a" 10 30)
    claim.endpointId `shouldBe` qq.endpointId
    unknown <-
      withDb pool $
        completeDelivery "worker-a" claim.deliveryId (DeliveryUnknown "timeout after write" (addUTCTime (-1) now))
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
        completeDelivery "worker-a" claim.deliveryId (DeliveryAccepted (Just (NativeEventId "native-out")))
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
    _ <- withDb pool (completeDelivery "worker-a" claim.deliveryId (DeliveryAccepted (Just (NativeEventId "native-confirm"))))
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
    _ <- withDb pool (completeDelivery "worker-a" claim.deliveryId (DeliveryUnknown "response lost" now))
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
              canonicalContent = canonicalContentValue [ContentText "hello both sides"],
              renderedText = "hello both sides",
              compatibilitySegments = Array mempty,
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
              canonicalContent = canonicalContentValue [ContentText "status"],
              renderedText = "status",
              compatibilitySegments = Array mempty,
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
          capabilities = textCapabilities
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
          capabilities = textCapabilities
        }
  pure (qq, matrix)

textCapabilities :: PlatformCapabilities
textCapabilities =
  noCapabilities
    { canSendText = True,
      canReply = True,
      maxTextBytes = Just 32768
    }

inbound :: EndpointId -> UTCTime -> Text -> Text -> InboundEnvelope
inbound endpoint now eventId body =
  InboundEnvelope
    { endpointId = endpoint,
      nativeEventId = NativeEventId eventId,
      senderNativeId = NativeUserId "@alice:example.test",
      senderDisplayName = Just "Alice",
      occurredAt = addUTCTime (-1) now,
      receivedAt = now,
      eventKind = EventMessage,
      content = [ContentText body],
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
