-- | WeChat adapter for the aixed/WeChat-Hook Windows client hook.
-- SendTextMsg accepts {wxidorgid,msg}; ret=0 acknowledges injection but supplies
-- no native ID or echo, so sends remain accepted-unconfirmed. Human messages
-- from the bot's account are independent inbound events.
-- set_callback delivers event_type=1001 objects with msgid, type, timestamp,
-- wxid, sender, roomid and content. Callbacks are unsigned: use a private
-- listener and an unguessable path to protect sender identity.
-- Verified against WeChat 4.1.10.27 (2026-08-07); QueryDB/login probes fail there.
-- Names come from config; callback re-registration and a silence watchdog
-- monitor connectivity. Client upgrades can break the version-specific hook.
module Max.WechatHook
  ( WechatHookConfig (..),
    wechatHookBackend,
    wechatHookWorker,
    platformName,
    wechatHookCapabilities,
    bridgeConfigured,
    wechatHookContent,
    wechatHookInboundBody,
    parseQuote,
    parseImagePayload,
    ImagePayload (..),
    Quote (..),
    CallbackMsg (..),
    parseCallback,
    callbackPathSegments,
    displayNameFor,
  )
where

import Control.Applicative ((<|>))
import Control.Concurrent (threadDelay)
import Control.Concurrent.STM
  ( atomically,
    modifyTVar',
    newTVarIO,
    readTVarIO,
  )
import Control.Monad (forM, forever, unless, when)
import Data.Aeson
import Data.Aeson.Types (Parser, parseMaybe)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base64 qualified as B64
import Data.ByteString.Lazy qualified as BL
import Data.Foldable (for_)
import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Scientific (toBoundedInteger)
import Data.String (fromString)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Read qualified as TR
import Data.Time (diffUTCTime, getCurrentTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Effectful
import Effectful.Concurrent.Async (Concurrent, concurrently_)
import Effectful.Log
import Effectful.PostgreSQL (WithConnection, execute)
import Max.DB.PlatformIds qualified as PlatformIds
import Max.Effects.Blob (Blob, BlobRef, blobRefSha256, blobRefStoredPath, putBlob)
import Max.HttpRuntime
  ( BufferedResponse (body),
    HttpPool (StandardPool),
    HttpRuntime,
    TransportFailure (..),
    parseRequestEither,
    renderTransportFailure,
    runBuffered,
  )
import Max.IR
import Max.IR.Digest (digest)
import Max.IR.Lower (OutboundCaps (..), Tier (TierNative), textOnlyCaps)
import Max.Platform (PlatformBackend (..))
import Max.Platform.Envelope (InboundEnvelope (..), IngestClass (LiveDelivery))
import Max.Platform.Ingress (Ingress, queueIngest)
import Max.Platform.Store
  ( IngestResult (..),
    NewIngest (..),
    RegisteredEndpoint (..),
    defaultIngestOptions,
    ensureConfiguredEndpoint,
    ingestEnvelope,
  )
import Max.Platform.Types
  ( CanonicalMessageId (..),
    ConversationKind (ConversationGroup),
    EndpointMode (EndpointStandalone),
    EventKind (EventMessage),
    MessageRelation (ReplyTo),
    NativeAccountId (..),
    NativeConversationId (..),
    NativeEventId (..),
    NativeUserId (..),
    Platform (PlatformWeChatHook),
  )
import Max.Util (catchSync)
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Types (methodPost, status200, status404)
import Network.HTTP.Types.URI (urlEncode)
import Network.Wai qualified as Wai
import Network.Wai.Handler.Warp qualified as Warp
import OneBot.Action (Action (..), Response (..))
import OneBot.Segment (ImageSegInfo (..), Segment (..))
import OneBot.Types (GroupId (..), UserId (..))

platformName :: Text
platformName = "wechathook"

-- | Advertise images only with the Windows bridge that stages their files.
-- Other unsupported capabilities (mentions, quotes, reactions, recalls) remain
-- disabled and use text lowering where available.
wechatHookCapabilities :: WechatHookConfig -> OutboundCaps
wechatHookCapabilities cfg
  | bridgeConfigured cfg = textOnlyCaps {image = TierNative}
  | otherwise = textOnlyCaps

bridgeConfigured :: WechatHookConfig -> Bool
bridgeConfigured cfg = not (T.null (T.strip cfg.whBridgeUrl))

data WechatHookConfig = WechatHookConfig
  { -- | WeChat-Hook HTTP base, as reachable from max, e.g.
    -- @http:\/\/b650.tailnet:30001@.
    whApiUrl :: !Text,
    -- | Address the callback listener binds.  Defaults to loopback; a
    -- cross-host deployment must widen it to the private interface only.
    whListenHost :: !Text,
    whListenPort :: !Int,
    -- | Path the listener answers on, e.g. @\/wechat\/\<secret\>\/callback@.
    -- The secret segment is the only thing standing between an unsigned
    -- callback and max's authorization layer, so treat it as a credential.
    whCallbackPath :: !Text,
    -- | The URL the DLL should POST to, as reachable /from the Windows host/.
    -- Registered on startup and re-asserted by the watchdog, because
    -- @set_callback@ is DLL-process state that a WeChat restart discards.
    whCallbackUrl :: !Text,
    -- | The bot account's own wxid.
    whSelfWxid :: !Text,
    -- | Display name members @ the bot by.
    whBotName :: !Text,
    -- | Chatroom whitelist (@xxx\@chatroom@ ids); everything else, direct
    -- messages included, is ignored.
    whChatrooms :: ![Text],
    -- | Hand-maintained @wxid -> 昵称@.  The contact database is unreachable
    -- (see the module header), so an unlisted sender is honestly nameless
    -- rather than wearing a guessed identity.
    whNicknames :: !(Map Text Text),
    -- | Warn when no callback has arrived for this long.  @0@ disables it.
    whSilenceSeconds :: !Int,
    -- | @bridge\/wechat@ on the Windows host, empty when not deployed.  The
    -- hook moves images only through that host's own filesystem, so without
    -- the bridge there is no way to put a file there or read one back, and
    -- images stay degraded in both directions.
    whBridgeUrl :: !Text,
    whBridgeToken :: !Text
  }
  deriving stock (Show, Eq)

--------------------------------------------------------------------------------
-- Outbound backend.

-- | Build the outbound backend.  Runs its id lookup through the effect runner
-- the caller provides (Main closes it over the pool).
wechatHookBackend ::
  HttpRuntime ->
  (forall a. Eff '[WithConnection, IOE] a -> IO a) ->
  WechatHookConfig ->
  PlatformBackend
wechatHookBackend runtime runDb cfg =
  PlatformBackend
    { pbPlatform = platformName,
      pbName = platformName,
      pbSend = sendOut,
      pbCall = \a _timeoutMs ->
        sendOut a >>= \case
          Left err -> pure (Left err)
          Right () ->
            pure . Right $
              Response
                { status = "ok",
                  retcode = 0,
                  -- ret=0 acknowledges injection without a native ID or echo. Do not invent
                  -- an ID: delivery remains accepted-unconfirmed and cannot be a native target.
                  payload = object [],
                  echo = ""
                }
    }
  where
    sendOut :: Action -> IO (Either Text ())
    sendOut = \case
      SendGroupMsg (GroupId g) segs -> deliver "channel" g segs
      SendPrivateMsg (UserId u) segs -> deliver "user" u segs
      other -> pure (Left ("wechathook: unsupported action: " <> T.take 60 (T.pack (show other))))

    deliver kind mapped segs = do
      mNative <- runDb (PlatformIds.nativeId platformName kind mapped)
      case mNative of
        Nothing -> pure (Left ("wechathook: no native id for " <> T.pack (show mapped)))
        Just to -> case splitWire segs of
          Left err -> pure (Left err)
          Right (text, images) -> do
            -- WeChat carries no caption on an image, so words and picture are
            -- two messages however this is arranged.  Words go first: they are
            -- what the reply actually said, and an image that fails to send
            -- then costs the picture rather than the answer.
            sent <-
              if T.null (T.strip text)
                then pure (Right ())
                else postText runtime cfg to text
            case sent of
              Left err -> pure (Left err)
              Right () -> sendImages to images

    sendImages _ [] = pure (Right ())
    sendImages to (payload : rest) =
      resolveOutboundImage runtime payload >>= \case
        Left err -> pure (Left err)
        Right bytes ->
          postImage runtime cfg to bytes >>= \case
            Left err -> pure (Left err)
            Right () -> sendImages to rest

-- | Separate what this transport sends as words from what it sends as files.
-- Anything else is a violated lowering contract, never an invitation for an
-- adapter-local fallback.
splitWire :: [Segment] -> Either Text (Text, [Text])
splitWire = foldr step (Right ("", []))
  where
    step segment carry = do
      (text, images) <- carry
      case segment of
        SegText t -> Right (t <> text, images)
        SegImage info
          | Just file <- info.isiUrl -> Right (text, file : images)
          | otherwise -> Left "wechathook: lowering emitted an image with no payload"
        other -> Left ("wechathook: lowering emitted unsupported segment: " <> T.take 60 (T.pack (show other)))

-- | The lowerer hands over either inline bytes or somewhere to get them.
resolveOutboundImage :: HttpRuntime -> Text -> IO (Either Text ByteString)
resolveOutboundImage runtime payload
  | Just encoded <- T.stripPrefix "base64://" payload =
      pure $ case B64.decode (TE.encodeUtf8 encoded) of
        Right bytes -> Right bytes
        Left err -> Left ("wechathook: undecodable image payload: " <> T.pack err)
  | any (`T.isPrefixOf` T.toLower payload) ["http://", "https://"] =
      parseRequestEither (T.unpack payload) >>= \case
        Left failure -> pure (Left ("wechathook: " <> renderTransportFailure failure))
        Right request ->
          runBuffered runtime StandardPool maxImageBytes statusPreviewBytes request >>= \case
            Left failure -> pure (Left ("wechathook: " <> renderTransportFailure failure))
            Right response -> pure (Right response.body)
  | otherwise = pure (Left ("wechathook: unroutable image payload: " <> T.take 40 payload))

postText :: HttpRuntime -> WechatHookConfig -> Text -> Text -> IO (Either Text ())
postText runtime cfg to content =
  postJson runtime (cfg.whApiUrl <> "/SendTextMsg") payload >>= \case
    Left err -> pure (Left err)
    Right value -> pure $ case parseMaybe retCode value of
      Just 0 -> Right ()
      Just code -> Left ("wechathook: API ret " <> T.pack (show code))
      Nothing -> Left "wechathook: unparseable API response"
  where
    payload = object ["wxidorgid" .= to, "msg" .= content]
    retCode = withObject "envelope" (.: "ret") :: Value -> Parser Int

-- | One buffered JSON POST.  Every failure mode comes back as 'Left' text so
-- no caller has to decide whether an exception escaped.
postJson :: HttpRuntime -> Text -> Value -> IO (Either Text Value)
postJson runtime url payload =
  parseRequestEither (T.unpack url) >>= \case
    Left failure -> pure (Left ("wechathook: " <> renderTransportFailure failure))
    Right request0 -> do
      let request =
            request0
              { HTTP.method = "POST",
                HTTP.requestBody = HTTP.RequestBodyLBS (encode payload),
                HTTP.requestHeaders =
                  [ ("Content-Type", "application/json"),
                    -- The hook closes pooled connections without reliably notifying clients.
                    -- Use a fresh connection; retrying an ambiguous send on a stale one could
                    -- duplicate a message whose acknowledgement was lost.
                    ("Connection", "close")
                  ]
              }
      runBuffered runtime StandardPool maxResponseBytes statusPreviewBytes request >>= \case
        Left (HttpStatusFailure code _ preview _) ->
          pure . Left $
            "wechathook: HTTP "
              <> T.pack (show code)
              <> ": "
              <> T.take 300 (TE.decodeUtf8Lenient preview)
        Left failure -> pure (Left ("wechathook: " <> renderTransportFailure failure))
        Right response ->
          pure $ case decodeStrict' response.body of
            Just value -> Right value
            Nothing -> Left "wechathook: unparseable API response"

-- | POST raw image bytes to the bridge, which stages them on the Windows host
-- and hands the hook a path to read.
postImage :: HttpRuntime -> WechatHookConfig -> Text -> ByteString -> IO (Either Text ())
postImage runtime cfg to bytes
  | not (bridgeConfigured cfg) =
      pure (Left "wechathook: no bridge configured, images cannot be sent")
  | otherwise = do
      let url = T.dropWhileEnd (== '/') cfg.whBridgeUrl <> "/send-image?to=" <> urlEncodeText to
      parseRequestEither (T.unpack url) >>= \case
        Left failure -> pure (Left ("wechathook: " <> renderTransportFailure failure))
        Right request0 -> do
          let request =
                request0
                  { HTTP.method = "POST",
                    HTTP.requestBody = HTTP.RequestBodyBS bytes,
                    HTTP.requestHeaders =
                      [ ("Content-Type", "application/octet-stream"),
                        ("Authorization", TE.encodeUtf8 ("Bearer " <> cfg.whBridgeToken))
                      ]
                  }
          runBuffered runtime StandardPool maxResponseBytes statusPreviewBytes request >>= \case
            Left (HttpStatusFailure code _ preview _) ->
              pure . Left $
                "wechathook: bridge send-image HTTP "
                  <> T.pack (show code)
                  <> ": "
                  <> T.take 200 (TE.decodeUtf8Lenient preview)
            Left failure -> pure (Left ("wechathook: " <> renderTransportFailure failure))
            Right _ -> pure (Right ())

urlEncodeText :: Text -> Text
urlEncodeText = TE.decodeUtf8Lenient . urlEncode True . TE.encodeUtf8

-- | Ask the bridge for the picture an image callback described.  It answers
-- with JPEG bytes, having decrypted the stored file, verified it against these
-- numbers, and converted WeChat's HEVC wrapper if that is what it found.
fetchBridgeImage ::
  HttpRuntime ->
  WechatHookConfig ->
  ImagePayload ->
  -- | When the message arrived, bounding which stored files are candidates.
  Int64 ->
  IO (Either Text ByteString)
fetchBridgeImage runtime cfg payload occurredAt
  | not (bridgeConfigured cfg) = pure (Left "no bridge configured")
  | otherwise = do
      let url = T.dropWhileEnd (== '/') cfg.whBridgeUrl <> "/fetch-image"
          request =
            object
              [ "md5" .= payload.ipMd5,
                "origin_md5" .= payload.ipOriginMd5,
                "length" .= payload.ipLength,
                "hd_length" .= payload.ipHdLength,
                "after_unix" .= occurredAt
              ]
      parseRequestEither (T.unpack url) >>= \case
        Left failure -> pure (Left (renderTransportFailure failure))
        Right base -> do
          let httpRequest =
                base
                  { HTTP.method = "POST",
                    HTTP.requestBody = HTTP.RequestBodyLBS (encode request),
                    HTTP.requestHeaders =
                      [ ("Content-Type", "application/json"),
                        ("Authorization", TE.encodeUtf8 ("Bearer " <> cfg.whBridgeToken))
                      ]
                  }
          runBuffered runtime StandardPool maxImageBytes statusPreviewBytes httpRequest >>= \case
            Left (HttpStatusFailure code _ preview _) ->
              pure . Left $
                "bridge HTTP "
                  <> T.pack (show code)
                  <> ": "
                  <> T.take 200 (TE.decodeUtf8Lenient preview)
            Left failure -> pure (Left (renderTransportFailure failure))
            Right response
              | BS.null response.body -> pure (Left "bridge returned no bytes")
              | otherwise -> pure (Right response.body)

maxResponseBytes :: Int
maxResponseBytes = 1024 * 1024

-- | Ceiling on one image in either direction.  The bridge enforces its own;
-- this one keeps a runaway response from being read into memory here.
maxImageBytes :: Int
maxImageBytes = 32 * 1024 * 1024

statusPreviewBytes :: Int
statusPreviewBytes = 1024

--------------------------------------------------------------------------------
-- Inbound worker.

-- | Liveness state shared between the listener and the watchdog.  Both warning
-- flags are edge-triggered: a condition that persists is reported once, not
-- once per tick.
data Health = Health
  { hLastSeen :: !UTCTime,
    hSilenceWarned :: !Bool,
    hProbeFailing :: !Bool
  }

-- | Long-lived callback listener.  Every allowlisted room is registered as a
-- canonical endpoint before ingress opens. Commit each normalized event and its
-- media metadata, then queue its live dispatch in memory.
--
-- The watchdog runs alongside the listener rather than as its own worker
-- because it exists only to describe this listener's health.
wechatHookWorker ::
  (WithConnection :> es, Blob :> es, Log :> es, Concurrent :> es, IOE :> es) =>
  HttpRuntime ->
  WechatHookConfig ->
  Ingress ->
  Eff es ()
wechatHookWorker runtime cfg ingress = localDomain "wechathook" $ do
  logInfo "wechathook worker started" $
    object
      [ "chatrooms" .= cfg.whChatrooms,
        "listen" .= (cfg.whListenHost <> ":" <> T.pack (show cfg.whListenPort)),
        "path" .= cfg.whCallbackPath,
        "named_senders" .= Map.size cfg.whNicknames
      ]
  endpoints <- Map.fromList <$> forM cfg.whChatrooms registerRoom
  started <- liftIO getCurrentTime
  health <- liftIO (newTVarIO (Health started False False))
  registerCallback
  concurrently_ (listen endpoints health) (watchdog health)
  where
    pathSegs = callbackPathSegments cfg.whCallbackPath

    registerRoom room = do
      legacy <- PlatformIds.mappedId platformName "channel" room
      endpoint <-
        ensureConfiguredEndpoint
          PlatformWeChatHook
          (NativeAccountId cfg.whSelfWxid)
          (NativeConversationId room)
          ConversationGroup
          EndpointStandalone
          (Just legacy)
          (wechatHookCapabilities cfg)
      pure (room, endpoint)

    -- Doubles as the liveness probe: the DLL only answers while it is loaded
    -- into a running WeChat, so a failure here is the outage signal that
    -- @/QueryDB/status@ cannot give.
    probeCallback =
      liftIO $
        postJson runtime (cfg.whApiUrl <> "/set_callback") (object ["url" .= cfg.whCallbackUrl])

    registerCallback =
      probeCallback >>= \case
        Right _ -> logInfo "wechathook: callback registered" $ object ["url" .= cfg.whCallbackUrl]
        Left err -> logAttention "wechathook: callback registration failed" $ object ["error" .= err]

    listen endpoints health =
      withEffToIO (ConcUnlift Ephemeral Unlimited) $ \run ->
        Warp.runSettings settings $ \req respond -> do
          resp <-
            if Wai.requestMethod req == methodPost && Wai.pathInfo req == pathSegs
              then do
                raw <- Wai.strictRequestBody req
                -- Answer 200 whatever happens inside: the DLL has no retry
                -- semantics worth provoking, and a handler fault must not
                -- read as a transport fault.
                run (handleCallback endpoints health raw `catchSync` reportCrash)
                pure accepted
              else pure notFound
          respond resp

    settings =
      Warp.setHost (fromString (T.unpack cfg.whListenHost)) $
        Warp.setPort cfg.whListenPort Warp.defaultSettings

    reportCrash e =
      logAttention "wechathook: callback handler crashed" $
        object ["error" .= T.pack (show e)]

    handleCallback endpoints health raw = do
      now <- liftIO getCurrentTime
      -- Traffic is proof of life; leave the probe flag to the watchdog that
      -- owns it rather than clobbering a concurrent update.
      liftIO . atomically $
        modifyTVar' health (\h -> h {hLastSeen = now, hSilenceWarned = False})
      case decode raw >>= parseCallback of
        Nothing ->
          logAttention "wechathook: unparseable callback" $
            object ["preview" .= T.take 400 (TE.decodeUtf8Lenient (BL.toStrict raw))]
        Just cb -> translate endpoints now cb

    translate endpoints now cb
      -- Only the message event is understood.  Anything else is logged rather
      -- than dropped in silence, so a new event_type surfaces as evidence
      -- instead of as absence.
      | cb.cbEventType /= messageEventType =
          logInfo "wechathook: unhandled event type" $
            object ["event_type" .= cb.cbEventType, "type" .= cb.cbType]
      | T.null cb.cbRoomId = pure ()
      | Nothing <- Map.lookup cb.cbRoomId endpoints = pure ()
      | otherwise = do
          let endpoint = endpoints Map.! cb.cbRoomId
              nativeEvent = T.pack (show cb.cbMsgId)
              selfAuthored = cb.cbSender == cfg.whSelfWxid
          (body, relations, pendingImage) <- resolveContent cb
          let envelope =
                InboundEnvelope
                  { endpointId = endpoint.endpointId,
                    nativeEventId = NativeEventId nativeEvent,
                    senderNativeId = NativeUserId cb.cbSender,
                    senderDisplayName = displayNameFor cfg cb.cbSender,
                    occurredAt =
                      if cb.cbTimestamp > 0
                        then posixSecondsToUTCTime (fromIntegral cb.cbTimestamp)
                        else now,
                    receivedAt = now,
                    eventKind = EventMessage,
                    ingestClass = LiveDelivery,
                    content = body,
                    relations,
                    sourceCursor = Nothing,
                    rawPayload = Just (toJSON cb)
                  }
          unless selfAuthored $
            logInfo "wechat message" $
              object
                [ "chatroom" .= cb.cbRoomId,
                  "sender" .= cb.cbSender,
                  "len" .= T.length cb.cbContent,
                  "create_time" .= cb.cbTimestamp
                ]
          ingestEnvelope defaultIngestOptions envelope >>= \case
            Ingested fresh -> do
              -- The canonical id only exists once the ingest transaction has
              -- committed, so the media tables are written here rather than
              -- alongside the blob.  Without these rows the picture is in the
              -- body and in the store, and 'view_image' still cannot find it:
              -- that tool reads @message_images@, not the canonical body.
              for_ pendingImage (recordInboundImage fresh.canonicalMessageId)
              liftIO (queueIngest ingress (Ingested fresh))
              logInfo "wechat event ingested" $
                object
                  [ "native_event_id" .= nativeEvent,
                    "canonical_message_id" .= fresh.canonicalMessageId,
                    "self_authored" .= selfAuthored,
                    "content" .= digest fresh.canonicalBody
                  ]
            AlreadyIngested {} -> pure ()
            -- Unreachable: this adapter never sets 'selfEventsAreEchoes',
            -- because max's own sends do not come back on this transport.
            -- Saying so out loud beats a silent catch-all if that ever changes.
            DeliveryEcho canonical ->
              logAttention "wechathook: unexpected echo reconciliation" $
                object ["native_event_id" .= nativeEvent, "canonical_message_id" .= canonical]
            EchoUnmatched ->
              logAttention "wechathook: unexpected unmatched echo" $
                object ["native_event_id" .= nativeEvent]

    -- An image callback names a picture it does not carry.  With a bridge
    -- deployed the bytes are fetched here, at ingest, and stored as a blob:
    -- the alternative is a URL in the canonical body, and that body is kept
    -- forever, so it would mean a bridge credential persisted in the message
    -- store to be read back by whoever reads messages.
    resolveContent cb
      | cb.cbType == imageMessageType,
        bridgeConfigured cfg,
        Just payload <- parseImagePayload cb.cbContent =
          liftIO (fetchBridgeImage runtime cfg payload cb.cbTimestamp) >>= \case
            Right bytes -> do
              ref <- putBlob bytes
              logInfo "wechat image stored" $
                object ["bytes" .= BS.length bytes, "sha256" .= blobRefSha256 ref]
              pure
                ( imageBody ref (BS.length bytes),
                  [],
                  Just (ref, BS.length bytes)
                )
            Left err -> do
              -- The picture is lost; the message is not.  Falling back to the
              -- marker this adapter emitted before the bridge existed keeps
              -- the event in the transcript instead of dropping it.
              logAttention "wechathook: image fetch failed, degrading to a marker" $
                object ["error" .= err, "native_event_id" .= T.pack (show cb.cbMsgId)]
              pure (plainContent cb)
      | otherwise = pure (plainContent cb)

    plainContent cb =
      let (body, relations) = wechatHookContent cfg.whSelfWxid cfg.whBotName cb.cbType cb.cbContent
       in (body, relations, Nothing)

    imageBody ref size =
      Body
        [ NMedia
            (mediaBlobRef (blobRefSha256 ref))
            MediaMeta
              { kind = MImage,
                -- The bridge converts whatever it found; JPEG is what comes
                -- back either way.
                mime = Just "image/jpeg",
                sizeBytes = Just (fromIntegral size),
                name = Nothing,
                description = Nothing,
                raw = Nothing
              }
        ]

    watchdog health = forever $ do
      liftIO (threadDelay watchdogIntervalMicros)
      probeCallback >>= \case
        Left err -> do
          current <- liftIO (readTVarIO health)
          unless current.hProbeFailing $ do
            logAttention "wechathook: hook unreachable — WeChat down, or the DLL unloaded" $
              object ["error" .= err]
            liftIO . atomically $ modifyTVar' health (\h -> h {hProbeFailing = True})
        Right _ -> do
          current <- liftIO (readTVarIO health)
          when current.hProbeFailing $ do
            logInfo "wechathook: hook reachable again, callback re-registered" $
              object ["url" .= cfg.whCallbackUrl]
            liftIO . atomically $ modifyTVar' health (\h -> h {hProbeFailing = False})
      when (cfg.whSilenceSeconds > 0) $ do
        now <- liftIO getCurrentTime
        current <- liftIO (readTVarIO health)
        let quiet = diffUTCTime now current.hLastSeen
        when (not current.hSilenceWarned && quiet > fromIntegral cfg.whSilenceSeconds) $ do
          logAttention "wechathook: no callback for a long time — check the WeChat session" $
            object ["quiet_seconds" .= (round quiet :: Int)]
          liftIO . atomically $ modifyTVar' health (\h -> h {hSilenceWarned = True})

-- | Register a fetched picture in the media tables the image tools read.
-- Both inserts are idempotent, so a redelivered callback costs nothing.
recordInboundImage ::
  (WithConnection :> es, IOE :> es) =>
  CanonicalMessageId ->
  (BlobRef, Int) ->
  Eff es ()
recordInboundImage canonical (ref, size) = do
  let sha = blobRefSha256 ref
  _ <-
    execute
      "INSERT INTO images (sha256, mime_type, bytes_size, local_path) \
      \ VALUES (?,?,?,?) ON CONFLICT (sha256) DO NOTHING"
      (sha, "image/jpeg" :: Text, fromIntegral size :: Int64, blobRefStoredPath ref)
  _ <-
    execute
      "INSERT INTO message_images (canonical_message_id, sha256, seg_index) \
      \ VALUES (?,?,0) ON CONFLICT DO NOTHING"
      (unCanonicalMessageId canonical, sha)
  pure ()

watchdogIntervalMicros :: Int
watchdogIntervalMicros = 60_000_000

messageEventType :: Int
messageEventType = 1001

accepted :: Wai.Response
accepted = Wai.responseLBS status200 [("Content-Type", "application/json")] "{\"ret\":0}"

notFound :: Wai.Response
notFound = Wai.responseLBS status404 [("Content-Type", "application/json")] "{\"ret\":-1}"

-- | @\"\/wechat\/s3cret\/callback\"@ → @[\"wechat\",\"s3cret\",\"callback\"]@,
-- matching wai's own 'pathInfo' decomposition.
callbackPathSegments :: Text -> [Text]
callbackPathSegments = filter (not . T.null) . T.splitOn "/"

-- | The configured name for a wxid, or 'Nothing'.  Never a fabricated one:
-- an unnamed sender reads as its wxid everywhere, which is ugly and true.
displayNameFor :: WechatHookConfig -> Text -> Maybe Text
displayNameFor cfg wxid = do
  name <- Map.lookup wxid cfg.whNicknames
  if T.null (T.strip name) then Nothing else Just name

--------------------------------------------------------------------------------
-- Content.

-- | Preserve the order of text and the only mention whose authenticated native
-- identity this adapter knows: the bot itself.  Other visible @names remain
-- text rather than being guessed into identities.
wechatHookBody :: Text -> Text -> Text -> Body 'Ingest
wechatHookBody selfWxid botName = Body . mergeText . go
  where
    token = "@" <> botName
    go input = case T.breakOn token input of
      (before, rest)
        | T.null rest -> [NText before | not (T.null before)]
        | otherwise ->
            [NText before | not (T.null before)]
              <> [NMention (NativeUserId selfWxid) botName]
              <> go (dropMentionGap (T.drop (T.length token) rest))
    -- WeChat separates an @-token from what follows with U+2005 (four-per-em
    -- space), not an ordinary space.  Accepting either keeps the separator
    -- from surviving into the text tier as a stray character.
    dropMentionGap t = fromMaybe t (T.stripPrefix "\x2005" t <|> T.stripPrefix " " t)

-- | Preserve every room event even when the callback does not expose a stable
-- native media reference.  Known non-text message kinds become explicit
-- unsupported nodes with a total human fallback and a bounded diagnostic
-- fragment; they can be inspected and mirrored instead of disappearing.
wechatHookInboundBody :: Text -> Text -> Int -> Text -> Body 'Ingest
wechatHookInboundBody selfWxid botName msgType content
  | msgType == 1 = wechatHookBody selfWxid botName content
  | otherwise =
      Body
        [ NUnsupported
            Unsupported
              { source = "wechathook:" <> T.pack (show msgType),
                description = wechatMessageDescription msgType,
                raw =
                  Just
                    ( object
                        [ "msg_type" .= msgType,
                          "content_preview" .= T.take 2048 content
                        ]
                    )
              }
        ]

-- | Recover content and quote relations from callbacks. A relation resolves
-- only if the quoted native ID was ingested; outgoing hook sends have no such
-- ID. Preserve the reply text even when its target cannot be resolved.
wechatHookContent :: Text -> Text -> Int -> Text -> (Body 'Ingest, [MessageRelation])
wechatHookContent selfWxid botName msgType content
  | msgType == appMessageType,
    Just quote <- parseQuote content =
      ( wechatHookBody selfWxid botName quote.qText,
        [ReplyTo (NativeEventId quote.qTargetId)]
      )
  | otherwise = (wechatHookInboundBody selfWxid botName msgType content, [])

-- | The reply a quote carries: what the sender wrote, and the native id of the
-- message they wrote it about.
data Quote = Quote
  { qText :: !Text,
    qTargetId :: !Text
  }
  deriving stock (Eq, Show)

-- | Parse the quote fields of a type-49 app message, returning Nothing for
-- unsupported shapes. Split at refermsg first: outer type=57 identifies the
-- quote, while the inner type describes its target.
parseQuote :: Text -> Maybe Quote
parseQuote xml = do
  let (outer, refer) = T.breakOn "<refermsg>" xml
  if T.null refer
    then Nothing
    else do
      subtype <- tagText "type" outer
      if T.strip subtype /= quoteSubtype
        then Nothing
        else do
          target <- T.strip <$> tagText "svrid" refer
          if T.null target
            then Nothing
            else Just Quote {qText = fromMaybe "" (tagText "title" outer), qTargetId = target}

-- | Body of the first @\<tag\>…\</tag\>@ pair, entity-decoded.
tagText :: Text -> Text -> Maybe Text
tagText tag input =
  let open = "<" <> tag <> ">"
      close = "</" <> tag <> ">"
      (_, atOpen) = T.breakOn open input
   in if T.null atOpen
        then Nothing
        else
          let (inner, rest) = T.breakOn close (T.drop (T.length open) atOpen)
           in if T.null rest then Nothing else Just (unescapeXml inner)

-- | @&amp;@ resolves last: undoing it first would turn a literally escaped
-- @&amp;lt;@ into a @<@ that was never in the text.
unescapeXml :: Text -> Text
unescapeXml =
  T.replace "&amp;" "&"
    . T.replace "&#39;" "'"
    . T.replace "&apos;" "'"
    . T.replace "&quot;" "\""
    . T.replace "&gt;" ">"
    . T.replace "&lt;" "<"

-- | WeChat's catch-all for app messages: files, links, quotes and more all
-- arrive under it, separated only by the inner subtype.
appMessageType :: Int
appMessageType = 49

imageMessageType :: Int
imageMessageType = 3

-- | What an image callback says about a picture it does not carry.  The bytes
-- are on the Windows host, encrypted; these are the numbers that identify
-- which stored file is the one.
data ImagePayload = ImagePayload
  { ipMd5 :: !Text,
    ipOriginMd5 :: !Text,
    ipLength :: !Int64,
    ipHdLength :: !Int64
  }
  deriving stock (Eq, Show)

parseImagePayload :: Text -> Maybe ImagePayload
parseImagePayload xml
  | T.null md5 && T.null originMd5 && len == 0 && hdLen == 0 = Nothing
  | otherwise =
      Just
        ImagePayload
          { ipMd5 = md5,
            ipOriginMd5 = originMd5,
            ipLength = len,
            ipHdLength = hdLen
          }
  where
    md5 = fromMaybe "" (attrText "md5" xml)
    originMd5 = fromMaybe "" (attrText "originsourcemd5" xml)
    len = attrInt "length" xml
    hdLen = attrInt "hdlength" xml

-- | Value of a top-level attribute.
--
-- The leading space is not decoration: searching for @length=@ alone also
-- finds @cdnthumblength=@, and reading a thumbnail's size as the image's would
-- send the bridge looking for a file that does not exist.
attrText :: Text -> Text -> Maybe Text
attrText name input =
  let needle = " " <> name <> "=\""
      (_, atNeedle) = T.breakOn needle input
   in if T.null atNeedle
        then Nothing
        else
          let (value, rest) = T.breakOn "\"" (T.drop (T.length needle) atNeedle)
           in if T.null rest then Nothing else Just value

attrInt :: Text -> Text -> Int64
attrInt name input = case attrText name input of
  Just value -> either (const 0) fst (TR.decimal (T.strip value))
  Nothing -> 0

quoteSubtype :: Text
quoteSubtype = "57"

wechatMessageDescription :: Int -> Text
wechatMessageDescription = \case
  3 -> "微信图片消息"
  34 -> "微信语音消息"
  43 -> "微信视频消息"
  47 -> "微信表情消息"
  49 -> "微信分享或文件消息"
  10000 -> "微信系统消息"
  msgType -> "微信消息（类型 " <> T.pack (show msgType) <> "）"

--------------------------------------------------------------------------------
-- Callback model.

data CallbackMsg = CallbackMsg
  { cbEventType :: !Int,
    cbMsgId :: !Int64,
    cbType :: !Int,
    -- | WeChat's own send timestamp (unix seconds).  @messages.received_at@
    -- records local ingest, so this is the authoritative trace of when the
    -- sender actually sent it and becomes the envelope's occurred_at.
    cbTimestamp :: !Int64,
    -- | The conversation.  Equal to 'cbRoomId' for chatroom messages and the
    -- peer's wxid for a direct one, which is why 'cbRoomId' — not this — is
    -- what decides group versus direct.
    cbWxid :: !Text,
    cbSender :: !Text,
    cbRoomId :: !Text,
    cbContent :: !Text
  }
  deriving stock (Eq, Show)

instance ToJSON CallbackMsg where
  toJSON cb =
    object
      [ "event_type" .= cb.cbEventType,
        "msgid" .= cb.cbMsgId,
        "type" .= cb.cbType,
        "timestamp" .= cb.cbTimestamp,
        "wxid" .= cb.cbWxid,
        "sender" .= cb.cbSender,
        "roomid" .= cb.cbRoomId,
        "content" .= cb.cbContent
      ]

parseCallback :: Value -> Maybe CallbackMsg
parseCallback = parseMaybe callbackParser

callbackParser :: Value -> Parser CallbackMsg
callbackParser = withObject "callback" $ \o -> do
  eventType <- o .:? "event_type" .!= messageEventType
  msgid <- int64Field o "msgid"
  ty <- o .:? "type" .!= 1
  timestamp <- int64Field o "timestamp"
  wxid <- o .:? "wxid" .!= ""
  sender <- o .:? "sender" .!= ""
  roomid <- o .:? "roomid" .!= ""
  content <- o .:? "content" .!= ""
  pure (CallbackMsg eventType msgid ty timestamp wxid sender roomid content)
  where
    -- msgid arrives as a JSON number near 2^63; a stringified variant would
    -- still be an integer, so accept both rather than silently zeroing one.
    int64Field o k =
      (o .:? k) >>= \case
        Just (Number n) -> pure (fromMaybe 0 (toBoundedInteger n))
        Just (String s) -> pure (either (const 0) fst (TR.signed TR.decimal s))
        _ -> pure 0
