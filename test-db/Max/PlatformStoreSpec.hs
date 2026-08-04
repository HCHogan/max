module Max.PlatformStoreSpec (spec) where

import Control.Concurrent.Async (concurrently)
import Data.Aeson (Value (..), object, toJSON, (.=))
import Data.Int (Int64)
import Data.String (fromString)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime, addUTCTime, getCurrentTime)
import Database.PostgreSQL.Simple (Only (..), execute, execute_, query, withTransaction)
import Helpers (truncateAll, withDb)
import Max.DB.Connection (DbPool, withConn)
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

  it "discards a provider receipt already owned by another delivery" $ do
    (qq, matrix) <- mirrorPair pool
    now <- getCurrentTime
    _ <- withDb pool (ingestEnvelope defaultIngestOptions (inbound matrix.endpointId now "mx-reused-1" "first"))
    _ <- withDb pool (ingestEnvelope defaultIngestOptions (inbound matrix.endpointId now "mx-reused-2" "second"))
    claims <- withDb pool (claimDeliveries "worker-a" 10 30)
    claims `shouldSatisfy` \xs -> length xs == 2 && all (\claim -> claim.endpointId == qq.endpointId) xs
    case claims of
      [firstClaim, secondClaim] -> do
        withDb pool (completeDelivery "worker-a" firstClaim.deliveryId (DeliveryAccepted (Just (NativeEventId "reused-native"))))
          `shouldReturn` True
        withDb pool (completeDelivery "worker-a" secondClaim.deliveryId (DeliveryAccepted (Just (NativeEventId "reused-native"))))
          `shouldReturn` True
        deliveries <- withConn pool $ \conn ->
          query
            conn
            "SELECT status, native_event_id FROM message_deliveries WHERE endpoint_id = ? ORDER BY delivery_id"
            (Only qq.endpointId.unEndpointId)
        (deliveries :: [(Text, Maybe Text)])
          `shouldBe` [("accepted_unconfirmed", Just "reused-native"), ("accepted_unconfirmed", Nothing)]
      _ -> expectationFailure "expected two leased deliveries"

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
              canonicalContent = canonicalContentValue [ContentText "reply"],
              renderedText = "reply",
              compatibilitySegments = Array mempty,
              replyToCompatibilityMessageId = Just targetMessage
            }
    relations <- withConn pool $ \conn ->
      query
        conn
        "SELECT target_canonical_message_id FROM message_relations WHERE canonical_message_id = ? AND relation_kind = 'reply'"
        (Only queued.canonicalMessageId.unCanonicalMessageId)
    (relations :: [Only Int64]) `shouldBe` [Only (resultId target).unCanonicalMessageId]
    claims <- withDb pool (claimDeliveries "native-reply" 10 30)
    fmap (.replyNativeEventId) claims `shouldBe` [Just (NativeEventId "matrix-target")]

  it "keeps semantic mentions when a mirror has a QQ endpoint" $ do
    (qq, matrix) <- mirrorPair pool
    mirrorCaps <- withDb pool (conversationOutputCapabilities 42)
    mirrorCaps.canOutputReply `shouldBe` True
    mirrorCaps.canOutputQQMention `shouldBe` True
    mirrorCaps.canOutputQQFace `shouldBe` False
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
            { renderedTextOverride = Just "rendered\0text",
              compatibilitySegments = object ["text" .= ("segment\0text" :: Text)],
              compatibilityRawMessage = "raw\0message"
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

  it "repairs iMessage predecessor chains without losing real inline replies" $ do
    endpoint <-
      withDb pool $
        ensureConfiguredEndpoint
          PlatformIMessage
          (NativeAccountId "mac-account")
          (NativeConversationId "iMessage;+;chat-test")
          ConversationGroup
          EndpointStandalone
          Nothing
          textCapabilities
    now <- getCurrentTime
    parent <- withDb pool (ingestEnvelope defaultIngestOptions (inbound endpoint.endpointId now "parent" "parent"))
    _ <- withDb pool (ingestEnvelope defaultIngestOptions (inbound endpoint.endpointId now "previous" "previous"))
    let staleReplySegments =
          toJSON
            [ object
                [ "type" .= ("reply" :: Text),
                  "data" .= object ["id" .= ("-999" :: Text)]
                ]
            ]
        staleOptions :: IngestOptions
        staleOptions = defaultIngestOptions {PlatformStore.compatibilitySegments = staleReplySegments}
        falseEnvelope =
          (inbound endpoint.endpointId now "ambient-child" "ambient")
            { relations = [ReplyTo (NativeEventId "previous")],
              rawPayload = Just (object ["reply_to_guid" .= ("previous" :: Text)])
            }
        trueEnvelope =
          (inbound endpoint.endpointId now "inline-child" "inline")
            { relations = [ReplyTo (NativeEventId "previous")],
              rawPayload =
                Just
                  ( object
                      [ "reply_to_guid" .= ("previous" :: Text),
                        "thread_originator_guid" .= ("parent" :: Text)
                      ]
                  )
            }
    falseChild <- withDb pool (ingestEnvelope staleOptions falseEnvelope)
    trueChild <- withDb pool (ingestEnvelope staleOptions trueEnvelope)
    withConn pool $ \conn -> withTransaction conn $ do
      migration <- readFile "migrations/051_imessage_reply_semantics.sql"
      _ <- execute_ conn (fromString migration)
      [Only parentMessageId] <-
        query
          conn
          "SELECT message_id FROM messages WHERE canonical_message_id = ?"
          (Only (resultId parent).unCanonicalMessageId)
      repaired <-
        query
          conn
          "SELECT child.canonical_message_id, child.reply_to_message_id, \
          \       child.reply_to_canonical_message_id, child.segments->0->>'type', \
          \       child.segments->0->'data'->>'id', relation.target_canonical_message_id, \
          \       relation.target_native_event_id \
          \ FROM messages child \
          \ LEFT JOIN message_relations relation \
          \   ON relation.canonical_message_id = child.canonical_message_id \
          \  AND relation.relation_kind = 'reply' \
          \ WHERE child.canonical_message_id IN (?, ?) \
          \ ORDER BY child.canonical_message_id"
          ( (resultId falseChild).unCanonicalMessageId,
            (resultId trueChild).unCanonicalMessageId
          )
      (repaired :: [(Int64, Maybe Int64, Maybe Int64, Maybe Text, Maybe Text, Maybe Int64, Maybe Text)])
        `shouldBe` [ ( (resultId falseChild).unCanonicalMessageId,
                       Nothing,
                       Nothing,
                       Nothing,
                       Nothing,
                       Nothing,
                       Nothing
                     ),
                     ( (resultId trueChild).unCanonicalMessageId,
                       Just parentMessageId,
                       Just (resultId parent).unCanonicalMessageId,
                       Just "reply",
                       Just (T.pack (show parentMessageId)),
                       Just (resultId parent).unCanonicalMessageId,
                       Just "parent"
                     )
                   ]

  it "removes Mac attachment paths from existing iMessage raw provenance" $ do
    endpoint <-
      withDb pool $
        ensureConfiguredEndpoint
          PlatformIMessage
          (NativeAccountId "mac-account")
          (NativeConversationId "iMessage;+;chat-test")
          ConversationGroup
          EndpointStandalone
          Nothing
          textCapabilities
    now <- getCurrentTime
    let envelope =
          (inbound endpoint.endpointId now "attachment-path" "photo")
            { rawPayload =
                Just
                  ( object
                      [ "attachments"
                          .= [ object
                                 [ "path" .= ("/Users/max/Library/Messages/old.jpg" :: Text),
                                   "original_path" .= ("/Users/max/Library/Messages/photo.jpg" :: Text),
                                   "filename" .= ("~/Library/Messages/photo.jpg" :: Text),
                                   "transfer_name" .= ("photo.jpg" :: Text),
                                   "mime_type" .= ("image/jpeg" :: Text)
                                 ]
                             ]
                      ]
                  )
            }
    _ <- withDb pool (ingestEnvelope defaultIngestOptions envelope)
    withConn pool $ \conn -> withTransaction conn $ do
      migration <- readFile "migrations/052_imessage_raw_attachment_paths.sql"
      _ <- execute_ conn (fromString migration)
      payloads <-
        query
          conn
          "SELECT raw_payload FROM platform_events WHERE endpoint_id = ? AND native_event_id = 'attachment-path'"
          (Only endpoint.endpointId.unEndpointId)
      (payloads :: [Only Value])
        `shouldBe` [ Only
                       ( object
                           [ "attachments"
                               .= [ object
                                      [ "transfer_name" .= ("photo.jpg" :: Text),
                                        "mime_type" .= ("image/jpeg" :: Text)
                                      ]
                                  ]
                           ]
                       )
                   ]

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
            { PlatformStore.compatibilitySegments =
                toJSON
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
          (inbound endpoint.endpointId now "qq-image-roundtrip" "")
            { content =
                [ ContentMedia
                    (RemoteMedia imageUrl Nothing Nothing Nothing)
                    (Just "")
                ]
            }
    result <- withDb pool (ingestEnvelope options envelope)
    -- Recreate the projection written by the pre-fix renderer. The current
    -- renderer already fail-softs a blank caption to "[media]" at ingest.
    withConn pool $ \conn -> do
      _ <-
        execute
          conn
          "UPDATE messages SET rendered_text = '' WHERE canonical_message_id = ?"
          (Only (resultId result).unCanonicalMessageId)
      pure ()
    beforeRows <- withConn pool $ \conn ->
      query
        conn
        "SELECT rendered_text FROM messages WHERE canonical_message_id = ?"
        (Only (resultId result).unCanonicalMessageId)
    (beforeRows :: [Only Text]) `shouldBe` [Only ""]
    withConn pool $ \conn -> withTransaction conn $ do
      migration <- readFile "migrations/053_qq_image_dispatch_roundtrip.sql"
      _ <- execute_ conn (fromString migration)
      repaired <-
        query
          conn
          "SELECT m.rendered_text, m.canonical_content->0->>'caption', \
          \       f.payload->>'url', (f.payload->>'seg_index')::int, f.payload->>'kind' \
          \ FROM messages m \
          \ JOIN fetch_jobs f ON f.kind = 'image' \
          \  AND f.dedupe_key = m.message_id::text || ':0' \
          \ WHERE m.canonical_message_id = ?"
          (Only (resultId result).unCanonicalMessageId)
      (repaired :: [(Text, Text, Text, Int, Text)])
        `shouldBe` [("[image]", "[image]", imageUrl, 0, "image")]

  it "restores structural QQ mention projections without touching canonical identity" $ do
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
          (inbound endpoint.endpointId now "qq-mention-projection" "")
            { content =
                [ ContentMention (NativeUserId "2291939848") Nothing,
                  ContentText " hello"
                ]
            }
    result <- withDb pool (ingestEnvelope defaultIngestOptions envelope)
    beforeRows <- withConn pool $ \conn ->
      query
        conn
        "SELECT rendered_text FROM messages WHERE canonical_message_id = ?"
        (Only (resultId result).unCanonicalMessageId)
    (beforeRows :: [Only Text]) `shouldBe` [Only "@2291939848  hello"]
    withConn pool $ \conn -> withTransaction conn $ do
      migration <- readFile "migrations/054_qq_mention_projection.sql"
      _ <- execute_ conn (fromString migration)
      repaired <-
        query
          conn
          "SELECT rendered_text, canonical_content->0->>'native_user_id' \
          \FROM messages WHERE canonical_message_id = ?"
          (Only (resultId result).unCanonicalMessageId)
      (repaired :: [(Text, Text)])
        `shouldBe` [("[@#2291939848]  hello", "2291939848")]

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
