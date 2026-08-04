{-# LANGUAGE DeriveGeneric #-}

-- | Standalone iMessage conversation adapter over the authenticated Mac-side
-- @imsg-bridge@.  Catch-up is authoritative (@messages.after@); watch is only
-- a latency hint and is torn down periodically so durable reconciliation runs.
module Max.IMessage
  ( IMessageConfig (..),
    IMessagePage (..),
    IMessageMessage (..),
    IMessageMention (..),
    IMessageAttachment (..),
    IMessageBridgeHealth (..),
    IMessageSendState (..),
    parseIMessageBridgeHealth,
    parseIMessageSendState,
    parseIMessagePage,
    iMessageEventKind,
    iMessageIngressIdentity,
    iMessageReplyTarget,
    iMessageIsAddressed,
    iMessageTextNodes,
    iMessageSendTransport,
    iMessageAuthoritativeSendGuid,
    iMessageCapabilities,
    iMessageWorker,
    iMessageDeliveryTransport,
  )
where

import Control.Applicative ((<|>))
import Control.Concurrent qualified as Concurrent
import Control.Monad (forM, forM_, when)
import Data.Aeson
import Data.Aeson.Types (Parser, parseEither)
import Data.ByteString qualified as BS
import Data.Int (Int64)
import Data.List (find, sortOn)
import Data.Maybe (catMaybes, fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (getCurrentTime)
import Data.Time.Format.ISO8601 (iso8601ParseM)
import Effectful
import Effectful.Log
import Effectful.PostgreSQL (WithConnection)
import GHC.Generics (Generic)
import Max.Effects.Blob (Blob, blobRefSha256, putBlob)
import Max.EpisodeScheduler (EpisodeScheduler, bumpEpisode)
import Max.HttpRuntime
  ( BufferedResponse (body),
    HttpPool (StandardPool),
    HttpRuntime,
    TransportFailure (..),
    parseRequestEither,
    renderTransportFailure,
    runBuffered,
    withStreamingResponse,
  )
import Max.IR
import Max.IR.Lower (LoweredMessage (..), OutboundCaps (..), Tier (..), textOnlyCaps)
import Max.Platform.Delivery (DeliveryAttempt (..), DeliveryOperation (..), DeliveryTransport (..), loweredText)
import Max.Platform.Envelope (InboundEnvelope (..))
import Max.Platform.Store
  ( CursorRecord (..),
    IngestOptions (..),
    IngestResult (..),
    RegisteredEndpoint (..),
    UnconfirmedDelivery (..),
    advanceIngestCursorCAS,
    confirmUnconfirmedDelivery,
    defaultIngestOptions,
    ensureConfiguredEndpoint,
    ingestEnvelope,
    listUnconfirmedDeliveries,
    readIngestCursor,
    retryUnconfirmedDelivery,
  )
import Max.Platform.Types
import Max.Util (catchSync)
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Types.URI (urlEncode)
import OneBot.Types (GroupId (..))

data IMessageConfig = IMessageConfig
  { bridgeUrl :: !Text,
    bridgeToken :: !Text,
    accountKey :: !Text,
    chatGuid :: !Text,
    -- Stable Apple handles carried by confirmed mention metadata. These, not
    -- per-device contact display names, are authoritative identities.
    mentionHandles :: ![Text],
    -- Backwards-compatible literal @alias fallback for manually typed text.
    botName :: !Text,
    pollIntervalMs :: !Int
  }
  deriving stock (Eq, Generic)

instance Show IMessageConfig where
  show cfg =
    "IMessageConfig {bridgeUrl = "
      <> show cfg.bridgeUrl
      <> ", bridgeToken = <redacted>, accountKey = "
      <> show cfg.accountKey
      <> ", chatGuid = "
      <> show cfg.chatGuid
      <> ", mentionHandles = <"
      <> show (length cfg.mentionHandles)
      <> " configured>"
      <> ", botName = "
      <> show cfg.botName
      <> ", pollIntervalMs = "
      <> show cfg.pollIntervalMs
      <> "}"

data IMessageMessage = IMessageMessage
  { rowId :: !Int64,
    chatId :: !Int64,
    guid :: !Text,
    sender :: !Text,
    senderName :: !(Maybe Text),
    isFromMe :: !Bool,
    text :: !Text,
    createdAt :: !UTCTime,
    -- On the observed macOS 15 Messages schema this is a predecessor-chain
    -- pointer, not proof that the user explicitly replied. Provenance only.
    replyToGuid :: !(Maybe Text),
    -- The actual inline-reply root exposed by Messages.app.
    threadOriginatorGuid :: !(Maybe Text),
    mentions :: ![IMessageMention],
    mentionedHandles :: ![Text],
    isReaction :: !Bool,
    reactionKey :: !(Maybe Text),
    reactedToGuid :: !(Maybe Text),
    attachments :: ![IMessageAttachment],
    raw :: !Value
  }
  deriving stock (Eq, Show, Generic)

data IMessageMention = IMessageMention
  { handle :: !Text,
    display :: !Text,
    utf16Location :: !Int,
    utf16Length :: !Int
  }
  deriving stock (Eq, Show, Generic)

data IMessageAttachment = IMessageAttachment
  { attachmentId :: !Text,
    mimeType :: !(Maybe Text),
    byteSize :: !(Maybe Int64),
    transferName :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)

data IMessagePage = IMessagePage
  { messages :: ![IMessageMessage],
    nextRowId :: !Int64,
    hasMore :: !Bool
  }
  deriving stock (Eq, Show, Generic)

data BridgeFailure
  = BridgeBeforeEffect !Text
  | BridgeRejected !Text
  | BridgeOutcomeUnknown !Text
  deriving stock (Eq, Show)

data IMessageSendState
  = IMessageSendPending
  | IMessageSendSent
  | IMessageSendDelivered
  | IMessageSendFailed
  deriving stock (Eq, Show)

data IMessageBridgeHealth = IMessageBridgeHealth
  { sourceFingerprint :: !Text,
    nativeReplies :: !Bool
  }
  deriving stock (Eq, Show, Generic)

iMessageCapabilities :: OutboundCaps
iMessageCapabilities =
  textOnlyCaps
    { image = TierNative,
      sticker = TierNative,
      video = TierNative,
      audio = TierNative,
      file = TierNative,
      -- The conservative baseline is the public AppleScript transport. The
      -- worker advertises reply=true only while the bridge reports a live
      -- injected IMCore helper.
      reply = TierText,
      maxTextBytes = Just 65536
    }

iMessageWorker ::
  (Blob :> es, WithConnection :> es, Log :> es, IOE :> es) =>
  HttpRuntime ->
  IMessageConfig ->
  Maybe EpisodeScheduler ->
  Eff es ()
iMessageWorker runtime cfg episodeScheduler = localDomain "imessage" $ do
  health <-
    liftIO (fetchBridgeHealth runtime cfg)
      >>= either (error . T.unpack . bridgeFailureText) pure
  registered <-
    ensureConfiguredEndpoint
      PlatformIMessage
      (NativeAccountId cfg.accountKey)
      (NativeConversationId cfg.chatGuid)
      ConversationGroup
      EndpointStandalone
      Nothing
      (iMessageCapabilitiesFor health.nativeReplies)
  logInfo "iMessage worker started" $
    object
      [ "chat_guid" .= cfg.chatGuid,
        "endpoint_id" .= registered.endpointId,
        "native_replies" .= health.nativeReplies
      ]
  loop registered health.nativeReplies
  where
    loop registered advertisedNativeReplies = do
      nextNativeReplies <-
        runCycle registered advertisedNativeReplies `catchSync` \e -> do
          logAttention "iMessage cycle failed; cursor retained" $
            object ["error" .= T.pack (show e)]
          liftIO (Concurrent.threadDelay (cfg.pollIntervalMs * 1000))
          pure advertisedNativeReplies
      loop registered nextNativeReplies

    runCycle registered advertisedNativeReplies = do
      health <-
        liftIO (fetchBridgeHealth runtime cfg)
          >>= either (error . T.unpack . bridgeFailureText) pure
      when (health.nativeReplies /= advertisedNativeReplies) $ do
        _ <-
          ensureConfiguredEndpoint
            PlatformIMessage
            (NativeAccountId cfg.accountKey)
            (NativeConversationId cfg.chatGuid)
            ConversationGroup
            EndpointStandalone
            Nothing
            (iMessageCapabilitiesFor health.nativeReplies)
        logAttention "iMessage native reply capability changed" $
          object ["native_replies" .= health.nativeReplies]
      reconcileSends
      (chatId, cursor) <- catchUp registered health.sourceFingerprint
      -- Watch is a wake-up hint.  The bridge closes a quiet stream after 30s;
      -- either a notification or EOF returns here and the next cycle pages the
      -- authoritative physical ROWID cursor again.
      liftIO (watchOnce runtime cfg chatId cursor) >>= \case
        Left err -> do
          logInfo "iMessage watch ended" $ object ["reason" .= err]
          liftIO (Concurrent.threadDelay (cfg.pollIntervalMs * 1000))
        Right () -> pure ()
      pure health.nativeReplies

    catchUp registered fingerprint = do
      chatId <- liftIO (resolveChat runtime cfg) >>= either (error . T.unpack . bridgeFailureText) pure
      current <- readIngestCursor registered.platformAccountId iMessageStreamKey
      let sourceReset = maybe False ((/= Just fingerprint) . (.fingerprint)) current
          bootstrap = current == Nothing || sourceReset
          since = if bootstrap then 0 else maybe 0 cursorRowId current
      when sourceReset $
        logAttention "iMessage source database changed; rescanning allowlisted chat by GUID" $
          object ["chat_guid" .= cfg.chatGuid, "source_fingerprint" .= fingerprint]
      pageFrom registered chatId fingerprint bootstrap current since

    pageFrom registered chatId fingerprint bootstrap current since = do
      page <-
        liftIO (fetchAfter runtime cfg chatId since) >>= either (error . T.unpack . bridgeFailureText) pure
      when (page.nextRowId < since) $
        error "iMessage: source returned a ROWID behind the committed cursor"
      forM_ page.messages (ingestIMessage registered bootstrap page.nextRowId)
      published <-
        advanceIngestCursorCAS
          registered.platformAccountId
          iMessageStreamKey
          ((.revision) <$> current)
          (PlatformCursor (Number (fromIntegral page.nextRowId)))
          (Just fingerprint)
      nextRecord <- case published of
        Nothing -> do
          logInfo "iMessage cursor CAS lost; page will deduplicate on replay" $
            object ["next_rowid" .= page.nextRowId]
          readIngestCursor registered.platformAccountId iMessageStreamKey >>= maybe (error "iMessage: cursor disappeared") pure
        Just record -> pure record
      if page.hasMore
        then pageFrom registered chatId fingerprint bootstrap (Just nextRecord) page.nextRowId
        else pure (chatId, page.nextRowId)

    ingestIMessage registered bootstrap next message = do
      received <- liftIO getCurrentTime
      parts <- messageContent runtime cfg message
      forM_ episodeScheduler $ \scheduler ->
        liftIO (bumpEpisode scheduler (GroupId registered.compatibilityConversationId))
      let kind = iMessageEventKind message
          relations =
            catMaybes
              [ ReplyTo . NativeEventId <$> iMessageReplyTarget message,
                if message.isReaction
                  then
                    (\target -> ReactsTo (NativeEventId target) (fromMaybe "reaction" message.reactionKey) ReactionAdd)
                      <$> message.reactedToGuid
                  else Nothing
              ]
          options =
            defaultIngestOptions
              { createDispatch = not bootstrap,
                transcriptKind = if kind == EventMessage then "chat" else "debug"
              }
          (senderNative, senderDisplayName) = iMessageIngressIdentity cfg message
          envelope =
            InboundEnvelope
              { endpointId = registered.endpointId,
                nativeEventId = NativeEventId message.guid,
                senderNativeId = senderNative,
                senderDisplayName,
                occurredAt = message.createdAt,
                receivedAt = received,
                eventKind = kind,
                content = Body parts,
                relations,
                sourceCursor = Just (PlatformCursor (Number (fromIntegral next))),
                rawPayload = Just message.raw
              }
      result <- ingestEnvelope options envelope
      case result of
        Ingested {} -> pure ()
        AlreadyIngested {} -> pure ()
        DeliveryEcho {} -> pure ()

    reconcileSends = do
      pending <- listUnconfirmedDeliveries PlatformIMessage iMessageReconcileBatchSize
      forM_ pending $ \delivery ->
        liftIO
          ( bridgeRpc
              runtime
              cfg
              "message.send_status"
              (object ["guid" .= delivery.nativeEventId.unNativeEventId])
          )
          >>= \case
            Left err ->
              logInfo "iMessage send-status reconciliation deferred" $
                object ["delivery_id" .= delivery.deliveryId, "reason" .= bridgeFailureText err]
            Right value -> case parseIMessageSendState value of
              Left err ->
                logAttention "iMessage send-status response rejected" $
                  object ["delivery_id" .= delivery.deliveryId, "error" .= err]
              Right IMessageSendPending -> pure ()
              Right IMessageSendSent -> confirm delivery
              Right IMessageSendDelivered -> confirm delivery
              Right IMessageSendFailed -> do
                _ <- retryUnconfirmedDelivery delivery.deliveryId delivery.nativeEventId "imsg reports send_state=failed"
                pure ()
      where
        confirm delivery = do
          _ <- confirmUnconfirmedDelivery delivery.deliveryId delivery.nativeEventId
          pure ()

-- Some Messages database rows (for example group-photo changes) have no
-- sender handle.  They remain durable provenance but are system events,
-- never chat turns or proactive triggers.
iMessageEventKind :: IMessageMessage -> EventKind
iMessageEventKind message
  | isUnattributedSystemEvent message = EventMembership
  | message.isReaction = EventReaction
  | otherwise = EventMessage

iMessageIngressIdentity :: IMessageConfig -> IMessageMessage -> (NativeUserId, Maybe Text)
iMessageIngressIdentity cfg message
  | message.isFromMe = (NativeUserId cfg.accountKey, message.senderName)
  | isUnattributedSystemEvent message = (NativeUserId "system", Just "iMessage system")
  | otherwise = (NativeUserId message.sender, message.senderName)

-- On the observed macOS 15 Messages schema, @reply_to_guid@ is a rolling
-- predecessor pointer set on ordinary top-level messages. Only
-- @thread_originator_guid@ proves use of Messages' inline-reply UI.
iMessageReplyTarget :: IMessageMessage -> Maybe Text
iMessageReplyTarget = (.threadOriginatorGuid)

iMessageIsAddressed :: IMessageConfig -> IMessageMessage -> Bool
iMessageIsAddressed cfg message =
  any
    (\mentioned -> any (sameHandle mentioned) cfg.mentionHandles)
    message.mentionedHandles
    || ("@" <> T.toCaseFold (T.strip cfg.botName)) `T.isInfixOf` T.toCaseFold message.text
  where
    sameHandle left right = T.toCaseFold (T.strip left) == T.toCaseFold (T.strip right)

isUnattributedSystemEvent :: IMessageMessage -> Bool
isUnattributedSystemEvent message =
  not message.isFromMe && T.null (T.strip message.sender)

iMessageDeliveryTransport :: HttpRuntime -> IMessageConfig -> DeliveryTransport
iMessageDeliveryTransport runtime cfg =
  DeliveryTransport
    { platform = PlatformIMessage,
      deliver = \claim -> \case
        DeliverMessage lowered -> sendChunks claim lowered
        DeliverEdit {} -> pure (AttemptPermanentlyFailed "iMessage endpoint advertised edit without an emitter")
        DeliverReaction {} -> pure (AttemptPermanentlyFailed "iMessage endpoint advertised reaction without an emitter")
        DeliverRedaction {} -> pure (AttemptPermanentlyFailed "iMessage endpoint advertised redaction without an emitter")
    }
  where
    sendChunks _claim lowered = go (0 :: Int) False Nothing lowered.chunks
      where
        go _ _ firstNative [] = pure (AttemptAccepted firstNative)
        go index sentAny firstNative (chunk : rest) =
          prepareChunk (if index == 0 then lowered.replyNative else Nothing) chunk >>= \case
            Left (IMessageContractFailure err) -> pure (AttemptPermanentlyFailed err)
            Left (IMessageMediaFailure err) ->
              pure $ if sentAny then AttemptOutcomeUnknown err else AttemptMediaFallback err
            Right (replyTarget, params) ->
              bridgeRpc runtime cfg "send" params >>= \case
                Left (BridgeBeforeEffect err) ->
                  pure $ if sentAny then AttemptOutcomeUnknown err else AttemptRetryable err
                Left (BridgeRejected err) ->
                  pure $ if sentAny then AttemptOutcomeUnknown err else AttemptRetryable err
                Left (BridgeOutcomeUnknown err) -> pure (AttemptOutcomeUnknown err)
                Right value -> case parseEither sendResultParser value of
                  Left err -> pure (AttemptOutcomeUnknown ("imsg send response: " <> T.pack err))
                  Right guid ->
                    go
                      (index + 1)
                      True
                      (firstNative <|> iMessageAuthoritativeSendGuid replyTarget guid)
                      rest

    prepareChunk replyTarget chunk = case loweredText chunk of
      Left err -> pure (Left (IMessageContractFailure err))
      Right body -> case [(payload, meta) | NMedia payload meta <- chunk] of
        [] -> pure (Right (replyTarget, sendParams replyTarget body Nothing))
        [(payload, meta)] ->
          resolveDeliveryMedia runtime payload meta.sizeBytes >>= \case
            Left err -> pure (Left (IMessageMediaFailure err))
            Right bytes ->
              uploadBridgeAttachment runtime cfg meta bytes >>= \case
                Left err -> pure (Left (IMessageMediaFailure err))
                Right uploadId ->
                  pure (Right (replyTarget, sendParams replyTarget body (Just ("upload:" <> uploadId))))
        _ -> pure (Left (IMessageContractFailure "iMessage emitter received more than one native media node"))

    sendParams replyTarget body upload =
      object
        ( [ "chat_guid" .= cfg.chatGuid,
            "text" .= body,
            "service" .= ("auto" :: Text),
            "transport" .= iMessageSendTransport replyTarget
          ]
            <> ["file" .= file | Just file <- [upload]]
            <> ["reply_to" .= target | Just (NativeEventId target) <- [replyTarget]]
        )

data IMessageEmitFailure
  = IMessageContractFailure !Text
  | IMessageMediaFailure !Text

-- | The injected IMCore helper is necessary only for native inline replies.
-- Keeping ordinary sends on AppleScript also gives them an authoritative GUID
-- resolved from Messages' database by imsg.
iMessageSendTransport :: Maybe NativeEventId -> Text
iMessageSendTransport = maybe "applescript" (const "bridge")

-- | The helper's immediate lastSentMessage GUID is best-effort and can be
-- stale. Native replies are therefore accepted without an id and confirmed by
-- the authoritative messages.after echo. AppleScript receipts remain usable.
iMessageAuthoritativeSendGuid :: Maybe NativeEventId -> Maybe Text -> Maybe NativeEventId
iMessageAuthoritativeSendGuid replyTarget guid =
  case replyTarget of
    Nothing -> NativeEventId <$> guid
    Just _ -> Nothing

resolveDeliveryMedia :: HttpRuntime -> ResolvedMedia -> Maybe Int64 -> IO (Either Text BS.ByteString)
resolveDeliveryMedia _ (ResolvedBytes bytes) _ = pure (Right bytes)
resolveDeliveryMedia runtime (ResolvedUrl sourceUrl) declaredSize
  | "http://" `T.isPrefixOf` sourceUrl || "https://" `T.isPrefixOf` sourceUrl =
        parseRequestEither (T.unpack sourceUrl) >>= \case
          Left failure -> pure (Left (renderTransportFailure failure))
          Right request ->
            runBuffered runtime StandardPool iMessageMaxAttachmentBytes bridgePreviewBytes request >>= \case
              Left failure -> pure (Left (renderTransportFailure failure))
              Right response
                | maybe False (/= fromIntegral (BS.length response.body)) declaredSize -> pure (Left "delivery media size changed")
                | otherwise -> pure (Right response.body)
  | otherwise = pure (Left "delivery media has no transferable source")

uploadBridgeAttachment ::
  HttpRuntime ->
  IMessageConfig ->
  MediaMeta ->
  BS.ByteString ->
  IO (Either Text Text)
uploadBridgeAttachment runtime cfg meta bytes = do
  let params =
        [ ("filename", fromMaybe "attachment" meta.name),
          ("mime_type", fromMaybe "application/octet-stream" meta.mime)
        ]
      url = T.dropWhileEnd (== '/') cfg.bridgeUrl <> "/outbound-attachment" <> queryText params
  parseRequestEither (T.unpack url) >>= \case
    Left failure -> pure (Left (renderTransportFailure failure))
    Right request0 -> do
      let request =
            request0
              { HTTP.method = "POST",
                HTTP.requestHeaders =
                  [ ("Authorization", "Bearer " <> TE.encodeUtf8 cfg.bridgeToken),
                    ("Content-Type", TE.encodeUtf8 (fromMaybe "application/octet-stream" meta.mime))
                  ],
                HTTP.requestBody = HTTP.RequestBodyBS bytes,
                HTTP.responseTimeout = HTTP.responseTimeoutMicro bridgeRpcTimeoutMicros
              }
      runBuffered runtime StandardPool bridgeMaxResponseBytes bridgePreviewBytes request >>= \case
        Left failure -> pure (Left (renderTransportFailure failure))
        Right response -> case eitherDecodeStrict' response.body >>= parseEither (withObject "bridge upload" (.: "upload_id")) of
          Left err -> pure (Left ("imsg bridge upload response: " <> T.pack err))
          Right uploadId -> pure (Right uploadId)

sendResultParser :: Value -> Parser (Maybe Text)
sendResultParser = withObject "imsg send" $ \o -> do
  ok <- o .:? "ok" .!= False
  if ok then o .:? "guid" else fail "send was not accepted"

parseIMessageSendState :: Value -> Either Text IMessageSendState
parseIMessageSendState = first T.pack . parseEither parser
  where
    parser = withObject "message.send_status" $ \o -> do
      ok <- o .:? "ok" .!= False
      when (not ok) (fail "status was not accepted")
      state <- o .: "send_state" :: Parser Text
      case state of
        "pending" -> pure IMessageSendPending
        "sent" -> pure IMessageSendSent
        "delivered" -> pure IMessageSendDelivered
        "failed" -> pure IMessageSendFailed
        other -> fail ("unknown send_state: " <> T.unpack other)

fetchBridgeHealth :: HttpRuntime -> IMessageConfig -> IO (Either BridgeFailure IMessageBridgeHealth)
fetchBridgeHealth runtime cfg =
  bridgeGet runtime cfg "/health" [] >>= \case
    Left err -> pure (Left err)
    Right value -> pure (either (Left . BridgeRejected) Right (parseIMessageBridgeHealth value))

parseIMessageBridgeHealth :: Value -> Either Text IMessageBridgeHealth
parseIMessageBridgeHealth = first T.pack . parseEither parser
  where
    parser = withObject "health" $ \o -> do
      fingerprint <- o .: "source_fingerprint"
      capabilities <- o .:? "capabilities" .!= Object mempty
      replies <- withObject "health capabilities" (\caps -> caps .:? "reply" .!= False) capabilities
      pure (IMessageBridgeHealth fingerprint replies)

iMessageCapabilitiesFor :: Bool -> OutboundCaps
iMessageCapabilitiesFor nativeReplies =
  iMessageCapabilities {reply = if nativeReplies then TierNative else TierText}

resolveChat :: HttpRuntime -> IMessageConfig -> IO (Either BridgeFailure Int64)
resolveChat runtime cfg =
  bridgeRpc runtime cfg "chats.list" (object ["limit" .= (500 :: Int)]) >>= \case
    Left err -> pure (Left err)
    Right value -> pure $ case parseEither parser value of
      Left err -> Left (BridgeRejected (T.pack err))
      Right chats -> case find ((== cfg.chatGuid) . snd) chats of
        Nothing -> Left (BridgeRejected "configured iMessage chat_guid is not present")
        Just (chatId, _) -> Right chatId
  where
    parser = withObject "chats.list" $ \o -> do
      chats <- o .:? "chats" .!= []
      forM chats $ withObject "chat" $ \chat -> (,) <$> chat .: "id" <*> chat .: "guid"

fetchAfter :: HttpRuntime -> IMessageConfig -> Int64 -> Int64 -> IO (Either BridgeFailure IMessagePage)
fetchAfter runtime cfg chatId since =
  bridgeRpc
    runtime
    cfg
    "messages.after"
    ( object
        [ "since_rowid" .= since,
          "chat_id" .= chatId,
          "limit" .= (500 :: Int),
          "attachments" .= True,
          "include_reactions" .= True
        ]
    )
    >>= \case
      Left err -> pure (Left err)
      Right value -> pure (either (Left . BridgeRejected) Right (parseIMessagePage value))

parseIMessagePage :: Value -> Either Text IMessagePage
parseIMessagePage = first T.pack . parseEither parser
  where
    parser = withObject "messages.after" $ \o ->
      IMessagePage
        <$> (o .:? "messages" .!= [] >>= traverse messageParser)
        <*> o .: "next_rowid"
        <*> o .:? "has_more" .!= False

messageParser :: Value -> Parser IMessageMessage
messageParser raw@(Object o) = do
  rowId <- o .: "id"
  chatId <- o .: "chat_id"
  guid <- o .: "guid"
  sender <- o .:? "sender" .!= ""
  senderName <- o .:? "sender_name"
  isFromMe <- o .:? "is_from_me" .!= False
  text <- o .:? "text" .!= ""
  createdText <- o .: "created_at"
  createdAt <- maybe (fail "invalid created_at") pure (iso8601ParseM (T.unpack createdText))
  replyToGuid <- o .:? "reply_to_guid"
  threadOriginatorGuid <- o .:? "thread_originator_guid"
  mentions <- o .:? "mentions" .!= [] >>= traverse mentionParser
  reportedHandles <- o .:? "mentioned_handles" .!= []
  isReaction <- o .:? "is_reaction" .!= False
  reactionType <- o .:? "reaction_type"
  reactionEmoji <- o .:? "reaction_emoji"
  reactedToGuid <- o .:? "reacted_to_guid"
  attachments <- o .:? "attachments" .!= [] >>= traverse attachmentParser
  let reactionKey = reactionEmoji <|> reactionType
      mentionedHandles = if null reportedHandles then map (.handle) mentions else reportedHandles
  pure IMessageMessage {rowId, chatId, guid, sender, senderName, isFromMe, text, createdAt, replyToGuid, threadOriginatorGuid, mentions, mentionedHandles, isReaction, reactionKey, reactedToGuid, attachments, raw}
messageParser _ = fail "message must be an object"

mentionParser :: Value -> Parser IMessageMention
mentionParser = withObject "mention" $ \o ->
  IMessageMention
    <$> o .: "handle"
    <*> o .: "display"
    <*> o .: "utf16_location"
    <*> o .: "utf16_length"

attachmentParser :: Value -> Parser IMessageAttachment
attachmentParser = withObject "attachment" $ \o ->
  IMessageAttachment
    <$> o .:? "attachment_id" .!= ""
    <*> o .:? "mime_type"
    <*> o .:? "byte_size"
    <*> o .:? "transfer_name"

messageContent ::
  (Blob :> es, Log :> es, IOE :> es) =>
  HttpRuntime ->
  IMessageConfig ->
  IMessageMessage ->
  Eff es [Node 'Ingest]
messageContent runtime cfg message = do
  media <- forM message.attachments $ \attachment ->
    if T.null attachment.attachmentId
      then pure (unavailableAttachment attachment)
      else do
        downloaded <- liftIO (fetchAttachment runtime cfg attachment)
        case downloaded of
          Left err -> do
            logAttention "iMessage attachment import failed; text remains durable" $
              object ["attachment_id" .= attachment.attachmentId, "error" .= err]
            pure (unavailableAttachment attachment)
          Right bytes -> do
            ref <- putBlob bytes
            let sha = blobRefSha256 ref
            pure $
              NMedia
                (mediaBlobRef sha)
                MediaMeta
                  { kind = mediaKindFromMime attachment.mimeType,
                    mime = attachment.mimeType,
                    sizeBytes = Just (fromIntegral (BS.length bytes)),
                    name = attachment.transferName,
                    description = Nothing,
                    raw = Nothing
                  }
  let parts = iMessageTextNodes cfg message <> media
  pure
    ( parts
        <> [ NUnsupported
               Unsupported {source = "imessage:empty", description = "empty message", raw = Nothing}
           | null parts
           ]
    )
  where
    unavailableAttachment attachment =
      NUnsupported
        Unsupported
          { source = "imessage:attachment-unavailable",
            description = fromMaybe "attachment unavailable" attachment.transferName,
            raw = Nothing
          }

-- Messages stores attributed-string ranges in UTF-16 code units.  Preserve
-- those exact ranges as semantic mentions; malformed or stale metadata is
-- ignored without sacrificing the authoritative plain text.
iMessageTextNodes :: IMessageConfig -> IMessageMessage -> [Node 'Ingest]
iMessageTextNodes _ message = mergeText (go 0 message.text (sortOn (.utf16Location) message.mentions))
  where
    go _ remaining [] = [NText remaining | not (T.null remaining)]
    go consumed remaining (mention : rest)
      | mention.utf16Location < consumed = go consumed remaining rest
      | otherwise = case splitAtUtf16 (mention.utf16Location - consumed) remaining of
          Nothing -> go consumed remaining rest
          Just (before, fromMention) -> case splitAtUtf16 mention.utf16Length fromMention of
            Just (display, after)
              | display == mention.display ->
                  [NText before | not (T.null before)]
                    <> [NMention (NativeUserId mention.handle) display]
                    <> go (mention.utf16Location + mention.utf16Length) after rest
            _ -> go consumed remaining rest

splitAtUtf16 :: Int -> Text -> Maybe (Text, Text)
splitAtUtf16 target input
  | target < 0 = Nothing
  | otherwise = do
      characters <- count 0 0 input
      pure (T.splitAt characters input)
  where
    count units characters remaining
      | units == target = Just characters
      | otherwise = case T.uncons remaining of
          Nothing -> Nothing
          Just (character, rest) ->
            let next = units + if fromEnum character > 0xFFFF then 2 else 1
             in if next > target then Nothing else count next (characters + 1) rest

mediaKindFromMime :: Maybe Text -> MediaKind
mediaKindFromMime = \case
  Just mime
    | "image/" `T.isPrefixOf` mime -> MImage
    | "video/" `T.isPrefixOf` mime -> MVideo
    | "audio/" `T.isPrefixOf` mime -> MAudio
  _ -> MFile

fetchAttachment :: HttpRuntime -> IMessageConfig -> IMessageAttachment -> IO (Either Text BS.ByteString)
fetchAttachment runtime cfg attachment = do
  bridgeRequest runtime cfg "GET" ("/attachment/" <> pathPiece attachment.attachmentId) [] Nothing False >>= \case
    Left failure -> pure (Left (bridgeFailureText failure))
    Right request ->
      runBuffered runtime StandardPool iMessageMaxAttachmentBytes bridgePreviewBytes request >>= \case
        Left failure -> pure (Left (renderTransportFailure failure))
        Right response
          | maybe False (/= fromIntegral (BS.length response.body)) attachment.byteSize ->
              pure (Left "iMessage attachment byte size changed during transfer")
          | otherwise -> pure (Right response.body)

watchOnce :: HttpRuntime -> IMessageConfig -> Int64 -> Int64 -> IO (Either Text ())
watchOnce runtime cfg chatId since = do
  let params = [("chat_id", T.pack (show chatId)), ("since_rowid", T.pack (show since))]
  bridgeRequest runtime cfg "GET" "/watch" params Nothing True >>= \case
    Left failure -> pure (Left (bridgeFailureText failure))
    Right request -> do
      result <- withStreamingResponse runtime StandardPool bridgePreviewBytes request (\_ reader -> awaitNotification reader)
      pure $ case result of
        Left failure -> Left (renderTransportFailure failure)
        Right () -> Right ()
  where
    awaitNotification reader = do
      chunk <- HTTP.brRead reader
      if BS.null chunk then pure () else pure ()

bridgeRpc :: HttpRuntime -> IMessageConfig -> Text -> Value -> IO (Either BridgeFailure Value)
bridgeRpc runtime cfg method params =
  bridgeGetOrPost runtime cfg "POST" "/rpc" [] (Just (object ["method" .= method, "params" .= params]))

bridgeGet :: HttpRuntime -> IMessageConfig -> Text -> [(Text, Text)] -> IO (Either BridgeFailure Value)
bridgeGet runtime cfg path params = bridgeGetOrPost runtime cfg "GET" path params Nothing

bridgeGetOrPost ::
  HttpRuntime ->
  IMessageConfig ->
  BS.ByteString ->
  Text ->
  [(Text, Text)] ->
  Maybe Value ->
  IO (Either BridgeFailure Value)
bridgeGetOrPost runtime cfg method path params payload =
  bridgeRequest runtime cfg method path params payload False >>= \case
    Left err -> pure (Left err)
    Right request ->
      runBuffered runtime StandardPool bridgeMaxResponseBytes bridgePreviewBytes request >>= \case
        Left (HttpStatusFailure status _ preview _) ->
          pure (Left (BridgeRejected ("imsg bridge HTTP " <> T.pack (show status) <> ": " <> TE.decodeUtf8Lenient preview)))
        Left failure -> pure (Left (BridgeOutcomeUnknown (renderTransportFailure failure)))
        Right response -> case eitherDecodeStrict' response.body of
          Left err -> pure (Left (BridgeRejected ("imsg bridge JSON: " <> T.pack err)))
          Right value -> pure (Right value)

bridgeRequest ::
  HttpRuntime ->
  IMessageConfig ->
  BS.ByteString ->
  Text ->
  [(Text, Text)] ->
  Maybe Value ->
  Bool ->
  IO (Either BridgeFailure HTTP.Request)
bridgeRequest _runtime cfg method path params payload streaming = do
  let url = T.dropWhileEnd (== '/') cfg.bridgeUrl <> path <> queryText params
  parseRequestEither (T.unpack url) >>= \case
    Left failure -> pure (Left (BridgeBeforeEffect (renderTransportFailure failure)))
    Right request0 ->
      pure . Right $
        request0
          { HTTP.method = method,
            HTTP.requestHeaders =
              [ ("Authorization", "Bearer " <> TE.encodeUtf8 cfg.bridgeToken),
                ("Content-Type", "application/json")
              ],
            HTTP.requestBody = maybe (HTTP.RequestBodyBS "") (HTTP.RequestBodyLBS . encode) payload,
            HTTP.responseTimeout = HTTP.responseTimeoutMicro (if streaming then bridgeWatchTimeoutMicros else bridgeRpcTimeoutMicros)
          }

bridgeFailureText :: BridgeFailure -> Text
bridgeFailureText = \case
  BridgeBeforeEffect err -> err
  BridgeRejected err -> err
  BridgeOutcomeUnknown err -> err

cursorRowId :: CursorRecord -> Int64
cursorRowId record = case record.cursor of
  PlatformCursor (Number value) -> floor value
  _ -> 0

queryText :: [(Text, Text)] -> Text
queryText [] = ""
queryText queryPairs =
  "?" <> T.intercalate "&" [encoded key <> "=" <> encoded value | (key, value) <- queryPairs]
  where
    encoded = TE.decodeUtf8 . urlEncode True . TE.encodeUtf8

pathPiece :: Text -> Text
pathPiece = TE.decodeUtf8 . urlEncode True . TE.encodeUtf8

iMessageStreamKey :: Text
iMessageStreamKey = "messages.after"

bridgeMaxResponseBytes :: Int
bridgeMaxResponseBytes = 16 * 1024 * 1024

iMessageMaxAttachmentBytes :: Int
iMessageMaxAttachmentBytes = 64 * 1024 * 1024

bridgePreviewBytes :: Int
bridgePreviewBytes = 4096

bridgeRpcTimeoutMicros :: Int
bridgeRpcTimeoutMicros = 90_000_000

bridgeWatchTimeoutMicros :: Int
bridgeWatchTimeoutMicros = 40_000_000

iMessageReconcileBatchSize :: Int
iMessageReconcileBatchSize = 32

first :: (a -> c) -> Either a b -> Either c b
first f = \case
  Left err -> Left (f err)
  Right value -> Right value
