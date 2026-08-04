{-# LANGUAGE DeriveGeneric #-}

-- | Matrix Client-Server adapter for one explicitly configured room.
--
-- Inbound sync uses the shared canonical cursor/ingest kernel; outbound sends
-- use a deterministic transaction id derived from the delivery row.  A
-- limited timeline is never accepted across an existing cursor until the
-- stored event boundary has been found via @/messages@ backfill.
module Max.Matrix
  ( MatrixConfig (..),
    MatrixSyncPage (..),
    MatrixEvent (..),
    parseMatrixSyncPage,
    matrixSelfMentionIsDirect,
    matrixMediaSizeDrift,
    matrixCapabilities,
    matrixWorker,
    matrixDeliveryTransport,
  )
where

import Control.Concurrent qualified as Concurrent
import Control.Applicative ((<|>))
import Control.Monad (forM_, when)
import Data.Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Pair, Parser, parseEither, parseMaybe)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Int (Int64)
import Data.List (findIndex)
import Data.Maybe (catMaybes, fromMaybe, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (getCurrentTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
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
  )
import Max.IR
import Max.IR.Lower (LoweredMessage (..), OutboundCaps (..), Tier (..), textOnlyCaps)
import Max.IR.Prompt (promptText)
import Max.Platform.Delivery (DeliveryAttempt (..), DeliveryTransport (..), loweredText)
import Max.Platform.Envelope (InboundEnvelope (..))
import Max.Platform.Store
  ( CursorRecord (..),
    DeliveryClaim (..),
    IngestOptions (..),
    IngestResult (..),
    NewIngest (..),
    RegisteredEndpoint (..),
    advanceIngestCursorCAS,
    compatibilityPlatformId,
    defaultIngestOptions,
    ensureConfiguredEndpoint,
    ingestEnvelope,
    latestNativeEventId,
    readIngestCursor,
  )
import Max.Platform.Types
import Max.Util (catchSync)
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Types.URI (urlDecode, urlEncode)
import OneBot.Segment (Segment (..))
import OneBot.Types (GroupId (..), MessageId (..), UserId (..))

data MatrixConfig = MatrixConfig
  { homeserver :: !Text,
    accessToken :: !Text,
    userId :: !Text,
    roomId :: !Text,
    mirrorQQGroup :: !(Maybe Int64),
    syncTimeoutMs :: !Int
  }
  deriving stock (Eq, Generic)

instance Show MatrixConfig where
  show cfg =
    "MatrixConfig {homeserver = "
      <> show cfg.homeserver
      <> ", accessToken = <redacted>, userId = "
      <> show cfg.userId
      <> ", roomId = "
      <> show cfg.roomId
      <> ", mirrorQQGroup = "
      <> show cfg.mirrorQQGroup
      <> ", syncTimeoutMs = "
      <> show cfg.syncTimeoutMs
      <> "}"

data MatrixEvent = MatrixEvent
  { eventId :: !NativeEventId,
    sender :: !NativeUserId,
    occurredAt :: !UTCTime,
    eventKind :: !EventKind,
    content :: ![Node 'Ingest],
    relations :: ![MessageRelation],
    mentionedUsers :: ![NativeUserId],
    raw :: !Value
  }
  deriving stock (Eq, Show)

data MatrixSyncPage = MatrixSyncPage
  { nextBatch :: !Text,
    events :: ![MatrixEvent],
    limited :: !Bool,
    prevBatch :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)

matrixCapabilities :: OutboundCaps
matrixCapabilities =
  textOnlyCaps
    { mention = TierNative,
      reply = TierNative,
      image = TierNative,
      sticker = TierNative,
      video = TierNative,
      audio = TierNative,
      file = TierNative,
      reaction = True,
      edit = True,
      redact = True,
      maxTextBytes = Just 65536
    }

matrixWorker ::
  (Blob :> es, WithConnection :> es, Log :> es, IOE :> es) =>
  HttpRuntime ->
  MatrixConfig ->
  Maybe EpisodeScheduler ->
  Eff es ()
matrixWorker runtime cfg episodeScheduler = localDomain "matrix" $ do
  registered <-
    ensureConfiguredEndpoint
      PlatformMatrix
      (NativeAccountId cfg.userId)
      (NativeConversationId cfg.roomId)
      ConversationGroup
      (maybe EndpointStandalone (const EndpointMirror) cfg.mirrorQQGroup)
      cfg.mirrorQQGroup
      matrixCapabilities
  selfCompatibility <- compatibilityPlatformId PlatformMatrix "user" cfg.userId
  logInfo "matrix worker started" $
    object
      [ "room_id" .= cfg.roomId,
        "endpoint_id" .= registered.endpointId,
        "mode" .= maybe ("standalone" :: Text) (const "mirror") cfg.mirrorQQGroup
      ]
  loop registered selfCompatibility
  where
    loop registered selfCompatibility = do
      syncOnce registered selfCompatibility `catchSync` \e -> do
        logAttention "matrix sync failed; cursor retained" $
          object ["error" .= T.pack (show e)]
        liftIO (Concurrent.threadDelay matrixFailureBackoffMicros)
      loop registered selfCompatibility

    syncOnce registered selfCompatibility = do
      current <- readIngestCursor registered.platformAccountId matrixStreamKey
      page <- liftIO (fetchSync runtime cfg (cursorText =<< current)) >>= either (error . T.unpack) pure
      boundary <- latestNativeEventId registered.endpointId
      gap <-
        if page.limited && current /= Nothing
          then case (boundary, page.prevBatch) of
            (Just eventBoundary, Just token) ->
              liftIO (fillGap runtime cfg eventBoundary token) >>= either (error . T.unpack) pure
            _ -> error "matrix: limited timeline has no recoverable boundary"
          else pure []
      let live = current /= Nothing
      forM_ (gap <> page.events) (ingestMatrixEvent live registered selfCompatibility page.nextBatch)
      published <-
        advanceIngestCursorCAS
          registered.platformAccountId
          matrixStreamKey
          ((.revision) <$> current)
          (PlatformCursor (String page.nextBatch))
          (Just (matrixSourceFingerprint cfg))
      when (published == Nothing) $
        logInfo "matrix cursor CAS lost; page will deduplicate on replay" $
          object ["next_batch" .= page.nextBatch]

    ingestMatrixEvent live registered selfCompatibility next event = do
      segments <- matrixCompatibilitySegments (NativeUserId cfg.userId) selfCompatibility event
      hydratedContent <- hydrateMatrixContent runtime cfg event
      received <- liftIO getCurrentTime
      forM_ episodeScheduler $ \scheduler ->
        liftIO (bumpEpisode scheduler (GroupId registered.compatibilityConversationId))
      let options =
            defaultIngestOptions
              { createDispatch = live,
                createMirrorDeliveries = live,
                transcriptKind = if event.eventKind == EventMessage then "chat" else "debug",
                compatibilitySegments = toJSON segments,
                compatibilityRawMessage = promptText PlatformMatrix (Body event.content)
              }
          envelope =
            InboundEnvelope
              { endpointId = registered.endpointId,
                nativeEventId = event.eventId,
                senderNativeId = event.sender,
                senderDisplayName = Just (unNativeUserId event.sender),
                occurredAt = event.occurredAt,
                receivedAt = received,
                eventKind = event.eventKind,
                content = Body hydratedContent,
                relations = event.relations,
                sourceCursor = Just (PlatformCursor (String next)),
                rawPayload = Just event.raw
              }
      result <- ingestEnvelope options envelope
      case result of
        Ingested fresh ->
          logInfo "matrix event ingested" $
            object ["event_id" .= event.eventId, "canonical_message_id" .= fresh.canonicalMessageId]
        AlreadyIngested {} -> pure ()
        DeliveryEcho {} -> pure ()

matrixCompatibilitySegments ::
  (WithConnection :> es, IOE :> es) =>
  NativeUserId ->
  Int64 ->
  MatrixEvent ->
  Eff es [Segment]
matrixCompatibilitySegments selfNative selfCompatibility event = do
  reply <- case [target | ReplyTo target <- event.relations] of
    target : _ -> do
      mapped <- compatibilityPlatformId PlatformMatrix "message" (unNativeEventId target)
      pure [SegReply (MessageId mapped)]
    [] -> pure []
  let mention = [SegAt (UserId selfCompatibility) | matrixSelfMentionIsDirect selfNative event]
  -- @mentionedUsers@ is converted by the caller-independent native id test:
  -- a synthetic at segment is needed only for Max itself.  The event parser
  -- preserves every other mention in canonical content.
  pure (reply <> mention <> [SegText (promptText PlatformMatrix (Body event.content))])

-- | Matrix includes the replied-to event's transport sender in @m.mentions@
-- so clients can notify them.  In a mirrored room every QQ event is delivered
-- by Max's Matrix account, even though its semantic author is a QQ user.  That
-- implicit notification must not become a synthetic @Max trigger: canonical
-- reply resolution below will independently wake Max only when the target was
-- actually bot-authored.
--
-- A mention on a non-reply is direct.  On a reply we require evidence in the
-- visible body outside the optional @mx-reply@ fallback, preserving an
-- explicit Matrix permalink mention without trusting the notification set.
matrixSelfMentionIsDirect :: NativeUserId -> MatrixEvent -> Bool
matrixSelfMentionIsDirect self event =
  self `elem` event.mentionedUsers
    && (not (any isReply event.relations) || explicitlyMentions self event.raw)
  where
    isReply ReplyTo {} = True
    isReply _ = False

explicitlyMentions :: NativeUserId -> Value -> Bool
explicitlyMentions (NativeUserId self) value = fromMaybe False (parseMaybe parser value)
  where
    encodedSelf = TE.decodeUtf8 (urlEncode True (TE.encodeUtf8 self))
    parser = withObject "matrix event" $ \event -> do
      content <- event .:? "content" .!= Object mempty
      withObject
        "matrix message content"
        ( \message -> do
            body <- message .:? "body" .!= ""
            formatted <- message .:? "formatted_body" .!= ""
            let visibleBody = dropPlainReplyFallback body
                visibleFormatted = dropReplyFallback formatted
                containsSelf text = self `T.isInfixOf` text || encodedSelf `T.isInfixOf` text
            pure (containsSelf visibleBody || containsSelf visibleFormatted)
        )
        content

dropReplyFallback :: Text -> Text
dropReplyFallback formatted
  | "<mx-reply>" `T.isPrefixOf` T.stripStart formatted =
      let (_, suffix) = T.breakOn "</mx-reply>" formatted
       in if T.null suffix then formatted else T.drop (T.length "</mx-reply>") suffix
  | otherwise = formatted

dropPlainReplyFallback :: Text -> Text
dropPlainReplyFallback body
  | "> " `T.isPrefixOf` T.stripStart body =
      let (_, suffix) = T.breakOn "\n\n" body
       in if T.null suffix then body else T.drop 2 suffix
  | otherwise = body

matrixDeliveryTransport :: HttpRuntime -> MatrixConfig -> DeliveryTransport
matrixDeliveryTransport runtime cfg =
  DeliveryTransport
    { platform = PlatformMatrix,
      deliver = sendChunks
    }
  where
    sendChunks claim lowered =
      go 0 Nothing lowered.chunks
      where
        go _ native [] = pure (AttemptConfirmed native)
        go chunkIndex native (chunk : rest) =
          matrixChunkPayload runtime cfg (if chunkIndex == 0 then lowered.replyNative else Nothing) chunk >>= \case
            Left (MatrixContractFailure err) -> pure (AttemptPermanentlyFailed err)
            Left (MatrixMediaFailure err) -> pure (AttemptMediaFallback err)
            Right payload ->
              sendMatrixDelivery runtime cfg claim chunkIndex payload >>= \case
                Left err -> pure (AttemptRetryable err)
                Right eventId -> go (chunkIndex + 1) (native <|> Just eventId) rest

matrixChunkPayload ::
  HttpRuntime ->
  MatrixConfig ->
  Maybe NativeEventId ->
  [Node 'Lowered] ->
  IO (Either MatrixEmitFailure Value)
matrixChunkPayload runtime cfg replyTarget chunk = case loweredText chunk of
  Left err -> pure (Left (MatrixContractFailure err))
  Right visibleBody -> case [(payload, meta) | NMedia payload meta <- chunk] of
    [] -> pure . Right $ matrixTextPayload replyTarget chunk visibleBody
    [(ResolvedUrl contentUri, meta)]
      | "mxc://" `T.isPrefixOf` contentUri ->
          pure . Right $ matrixMediaPayload replyTarget chunk visibleBody meta contentUri (fromIntegral <$> meta.sizeBytes)
    [(payload, meta)] ->
      resolveDeliveryMedia runtime payload meta.sizeBytes >>= \case
        Left err -> pure (Left (MatrixMediaFailure err))
        Right bytes ->
          uploadMatrixMedia runtime cfg meta bytes >>= \case
            Left err -> pure (Left (MatrixMediaFailure err))
            Right contentUri ->
              pure . Right $ matrixMediaPayload replyTarget chunk visibleBody meta contentUri (Just (BS.length bytes))
    _ -> pure (Left (MatrixContractFailure "Matrix emitter received more than one native media node"))

data MatrixEmitFailure
  = MatrixContractFailure !Text
  | MatrixMediaFailure !Text

matrixTextPayload :: Maybe NativeEventId -> [Node 'Lowered] -> Text -> Value
matrixTextPayload replyTarget chunk body =
  object
    ( [ "msgtype" .= ("m.text" :: Text),
        "body" .= body
      ]
        <> matrixRelations replyTarget chunk
    )

matrixMediaPayload :: Maybe NativeEventId -> [Node 'Lowered] -> Text -> MediaMeta -> Text -> Maybe Int -> Value
matrixMediaPayload replyTarget chunk visibleBody meta contentUri actualSize =
  object
    ( [ "msgtype" .= matrixMsgType meta.mime,
        "body" .= firstNonBlank [Just visibleBody, meta.description, meta.name, Just "attachment"],
        "filename" .= meta.name,
        "url" .= contentUri,
        "info"
          .= object
            [ "mimetype" .= meta.mime,
              "size" .= actualSize
            ]
      ]
        <> matrixRelations replyTarget chunk
    )

matrixRelations :: Maybe NativeEventId -> [Node 'Lowered] -> [Pair]
matrixRelations replyTarget chunk =
  matrixReplyRelation replyTarget <> matrixMentionRelation chunk

matrixReplyRelation :: Maybe NativeEventId -> [Pair]
matrixReplyRelation = \case
  Nothing -> []
  Just (NativeEventId target) ->
    [ "m.relates_to"
        .= object ["m.in_reply_to" .= object ["event_id" .= target]]
    ]

matrixMentionRelation :: [Node 'Lowered] -> [Pair]
matrixMentionRelation chunk = case [native | NMention (NativeUserId native) _ <- chunk] of
  [] -> []
  users -> ["m.mentions" .= object ["user_ids" .= users]]

matrixMsgType :: Maybe Text -> Text
matrixMsgType = \case
  Just mime
    | "image/" `T.isPrefixOf` mime -> "m.image"
    | "video/" `T.isPrefixOf` mime -> "m.video"
    | "audio/" `T.isPrefixOf` mime -> "m.audio"
  _ -> "m.file"

sendMatrixDelivery :: HttpRuntime -> MatrixConfig -> DeliveryClaim -> Int -> Value -> IO (Either Text NativeEventId)
sendMatrixDelivery runtime cfg claim chunkIndex payload = do
  let path =
        "/_matrix/client/v3/rooms/"
          <> pathPiece cfg.roomId
          <> "/send/m.room.message/"
          <> pathPiece (claim.idempotencyKey <> "-" <> T.pack (show chunkIndex))
  matrixRequest runtime cfg "PUT" path [] (Just payload) >>= \case
    Left err -> pure (Left err)
    Right response -> case parseEither (withObject "matrix send" (.: "event_id")) response of
      Left err -> pure (Left ("matrix send response: " <> T.pack err))
      Right event -> pure (Right (NativeEventId event))

resolveDeliveryMedia :: HttpRuntime -> ResolvedMedia -> Maybe Int64 -> IO (Either Text BS.ByteString)
resolveDeliveryMedia _ (ResolvedBytes bytes) _ = pure (Right bytes)
resolveDeliveryMedia runtime (ResolvedUrl sourceUrl) declaredSize
  | "http://" `T.isPrefixOf` sourceUrl || "https://" `T.isPrefixOf` sourceUrl =
        parseRequestEither (T.unpack sourceUrl) >>= \case
          Left failure -> pure (Left (renderTransportFailure failure))
          Right request ->
            runBuffered runtime StandardPool matrixMaxMediaBytes matrixStatusPreviewBytes request >>= \case
              Left failure -> pure (Left (renderTransportFailure failure))
              Right response
                | maybe False (/= fromIntegral (BS.length response.body)) declaredSize -> pure (Left "delivery media size changed")
                | otherwise -> pure (Right response.body)
  | otherwise = pure (Left "delivery media has no transferable source")

uploadMatrixMedia :: HttpRuntime -> MatrixConfig -> MediaMeta -> BS.ByteString -> IO (Either Text Text)
uploadMatrixMedia runtime cfg meta bytes = do
  let filename = fromMaybe "attachment" meta.name
      path = "/_matrix/media/v3/upload"
      url = T.dropWhileEnd (== '/') cfg.homeserver <> path <> queryText [("filename", filename)]
  parseRequestEither (T.unpack url) >>= \case
    Left failure -> pure (Left (renderTransportFailure failure))
    Right request0 -> do
      let request =
            request0
              { HTTP.method = "POST",
                HTTP.requestHeaders =
                  [ ("Authorization", "Bearer " <> TE.encodeUtf8 cfg.accessToken),
                    ("Content-Type", TE.encodeUtf8 (fromMaybe "application/octet-stream" meta.mime))
                  ],
                HTTP.requestBody = HTTP.RequestBodyBS bytes,
                HTTP.responseTimeout = HTTP.responseTimeoutMicro matrixHttpTimeoutMicros
              }
      runBuffered runtime StandardPool matrixMaxResponseBytes matrixStatusPreviewBytes request >>= \case
        Left failure -> pure (Left (renderTransportFailure failure))
        Right response -> case eitherDecodeStrict' response.body >>= parseEither (withObject "matrix upload" (.: "content_uri")) of
          Left err -> pure (Left ("Matrix media upload response: " <> T.pack err))
          Right contentUri -> pure (Right contentUri)

firstNonBlank :: [Maybe Text] -> Text
firstNonBlank = fromMaybe "attachment" . foldr choose Nothing
  where
    choose candidate rest = case T.strip <$> candidate of
      Just value | not (T.null value) -> Just value
      _ -> rest

fetchSync :: HttpRuntime -> MatrixConfig -> Maybe Text -> IO (Either Text MatrixSyncPage)
fetchSync runtime cfg since = do
  let params =
        [("timeout", T.pack (show cfg.syncTimeoutMs))]
          <> maybe [] (pure . ("since",)) since
          <> [("filter", matrixFilter cfg.roomId)]
  matrixRequest runtime cfg "GET" "/_matrix/client/v3/sync" params Nothing >>= \case
    Left err -> pure (Left err)
    Right value -> pure (parseMatrixSyncPage cfg.roomId value)

fillGap :: HttpRuntime -> MatrixConfig -> NativeEventId -> Text -> IO (Either Text [MatrixEvent])
fillGap runtime cfg boundary firstToken = go 0 firstToken []
  where
    go pages token newestFirst
      | pages >= maxGapPages = pure (Left "matrix: gap fill exceeded safety page limit")
      | otherwise = do
          let path = "/_matrix/client/v3/rooms/" <> pathPiece cfg.roomId <> "/messages"
          matrixRequest runtime cfg "GET" path [("from", token), ("dir", "b"), ("limit", "100")] Nothing >>= \case
            Left err -> pure (Left err)
            Right value -> case parseEither messagesPageParser value of
              Left err -> pure (Left ("matrix /messages: " <> T.pack err))
              Right (chunk, end) -> case findIndex ((== boundary) . (.eventId)) chunk of
                Just index -> pure (Right (reverse (newestFirst <> take index chunk)))
                Nothing
                  | null chunk || end == token -> pure (Left "matrix: stored boundary absent from limited timeline backfill")
                  | otherwise -> go (pages + 1) end (newestFirst <> chunk)

parseMatrixSyncPage :: Text -> Value -> Either Text MatrixSyncPage
parseMatrixSyncPage room value =
  first T.pack (parseEither parser value)
  where
    parser = withObject "sync" $ \root -> do
      next <- root .: "next_batch"
      rooms <- root .:? "rooms" .!= Object mempty
      (events, limited, prev) <- roomTimeline room rooms
      pure (MatrixSyncPage next events limited prev)

roomTimeline :: Text -> Value -> Parser ([MatrixEvent], Bool, Maybe Text)
roomTimeline room = withObject "rooms" $ \rooms -> do
  joins <- rooms .:? "join" .!= Object mempty
  withObject
    "joined rooms"
    ( \joined -> case KeyMap.lookup (Key.fromText room) joined of
        Nothing -> pure ([], False, Nothing)
        Just roomValue ->
          withObject
            "joined room"
            ( \roomObject -> do
                timeline <- roomObject .:? "timeline" .!= Object mempty
                withObject
                  "timeline"
                  ( \timelineObject -> do
                      rawEvents <- timelineObject .:? "events" .!= []
                      limited <- timelineObject .:? "limited" .!= False
                      prev <- timelineObject .:? "prev_batch"
                      pure (mapMaybe (parseMaybe matrixEventParser) rawEvents, limited, prev)
                  )
                  timeline
            )
            roomValue
    )
    joins

messagesPageParser :: Value -> Parser ([MatrixEvent], Text)
messagesPageParser = withObject "messages page" $ \o -> do
  rawEvents <- o .:? "chunk" .!= []
  end <- o .: "end"
  pure (mapMaybe (parseMaybe matrixEventParser) rawEvents, end)

matrixEventParser :: Value -> Parser MatrixEvent
matrixEventParser raw@(Object o) = do
  nativeEvent <- NativeEventId <$> o .: "event_id"
  sender <- NativeUserId <$> o .: "sender"
  timestampMs <- o .:? "origin_server_ts" .!= (0 :: Int64)
  eventType <- o .: "type" :: Parser Text
  contentValue <- o .:? "content" .!= Object mempty
  let occurredAt = posixSecondsToUTCTime (fromIntegral timestampMs / 1000)
      (eventKind, parts, relations, mentions) = normalizeMatrixContent eventType o contentValue
  pure MatrixEvent {eventId = nativeEvent, sender, occurredAt, eventKind, content = parts, relations, mentionedUsers = mentions, raw}
matrixEventParser _ = fail "matrix event must be an object"

normalizeMatrixContent :: Text -> Object -> Value -> (EventKind, [Node 'Ingest], [MessageRelation], [NativeUserId])
normalizeMatrixContent eventType eventObject contentValue = case eventType of
  "m.room.message" ->
    let relationInfo = relationFrom contentValue
        replacement = any isReplacement relationInfo
        -- The plain-text reply-fallback quote belongs to the transport,
        -- not the message: reply provenance lives in the relation, so the
        -- quote must not reach prompts or mirrors as body text.
        parts = messageParts (any isReplyRelation relationInfo) contentValue
     in (if replacement then EventEdit else EventMessage, parts, relationInfo, mentionsFrom contentValue)
  "m.reaction" -> (EventReaction, [unsupportedNode "reaction"], relationFrom contentValue, [])
  "m.room.redaction" ->
    let target = case KeyMap.lookup "redacts" eventObject of
          Just (String event) -> [Redacts (NativeEventId event)]
          _ -> []
     in (EventRedaction, [unsupportedNode "redaction"], target, [])
  "m.room.member" -> (EventMembership, [unsupportedNode "membership"], [], [])
  other -> (EventMembership, [unsupportedNode other], [], [])
  where
    isReplacement Replaces {} = True
    isReplacement _ = False
    isReplyRelation ReplyTo {} = True
    isReplyRelation _ = False
    unsupportedNode label =
      NUnsupported
        Unsupported
          { source = "matrix:" <> label,
            description = label,
            raw = Nothing
          }

messageParts :: Bool -> Value -> [Node 'Ingest]
messageParts stripReplyFallback value =
  fromMaybe
    [ NUnsupported
        Unsupported
          { source = "matrix:malformed-message",
            description = "malformed message",
            raw = Nothing
          }
    ]
    (parseMaybe parser value)
  where
    parser = withObject "message content" $ \o -> do
      msgtype <- o .:? "msgtype" .!= ("m.text" :: Text)
      body <- o .:? "body" .!= ""
      formatted <- o .:? "formatted_body" .!= ""
      mentioned <- o .:? "m.mentions" .!= Object mempty
      mentionedUsers <- withObject "m.mentions" (.:? "user_ids") mentioned .!= []
      url <- o .:? "url"
      info <- o .:? "info" .!= Object mempty
      (mime, size) <- withObject "media info" (\i -> (,) <$> i .:? "mimetype" <*> i .:? "size") info
      pure $ case (msgtype, url) of
        (kind, Just mxc)
          | kind `elem` ["m.image", "m.video", "m.audio", "m.file"] ->
              [ NMedia
                  (mediaRemoteRef mxc)
                  MediaMeta
                    { kind = matrixMediaKind kind,
                      mime,
                      sizeBytes = size,
                      name = nonEmpty body,
                      description = Nothing,
                      raw = Nothing
                    }
              ]
        _ ->
          let visible = if stripReplyFallback then dropPlainReplyFallback body else body
              visibleFormatted = if stripReplyFallback then dropReplyFallback formatted else formatted
              formattedAnchors = filter ((`elem` mentionedUsers) . fst) (matrixMentionAnchors visibleFormatted)
              anchoredUsers = map fst formattedAnchors
              anchors = formattedAnchors <> [(user, user) | user <- mentionedUsers, user `notElem` anchoredUsers]
           in mentionTextNodes visible anchors

-- Matrix's notification metadata identifies mention targets, while the
-- formatted body supplies the visible label and order.  The plain body stays
-- authoritative for all other text; anchors that do not occur in m.mentions
-- (notably reply fallbacks) never become semantic mentions.
matrixMentionAnchors :: Text -> [(Text, Text)]
matrixMentionAnchors = go
  where
    go input = case T.breakOn "<a " input of
      (_, rest) | T.null rest -> []
      (_, rest) ->
        let afterOpen = T.drop 3 rest
            (_, hrefStart) = T.breakOn "href=\"" afterOpen
         in if T.null hrefStart
              then go afterOpen
              else
                let hrefAndTail = T.drop 6 hrefStart
                    (href, afterHref) = T.breakOn "\"" hrefAndTail
                    (_, afterTagStart) = T.breakOn ">" afterHref
                    afterTag = T.drop 1 afterTagStart
                    (label, afterLabel) = T.breakOn "</a>" afterTag
                    remaining = T.drop 4 afterLabel
                 in case matrixToUser href of
                      Just user | not (T.null label) -> (user, label) : go remaining
                      _ -> go remaining

matrixToUser :: Text -> Maybe Text
matrixToUser href = do
  fragment <- sndNonEmpty (T.breakOn "#/" href)
  let encoded = T.takeWhile (/= '?') (T.drop 2 fragment)
      decoded = TE.decodeUtf8Lenient (urlDecode True (TE.encodeUtf8 encoded))
  if "@" `T.isPrefixOf` decoded then Just decoded else Nothing
  where
    sndNonEmpty (_, value)
      | T.null value = Nothing
      | otherwise = Just value

mentionTextNodes :: Text -> [(Text, Text)] -> [Node 'Ingest]
mentionTextNodes text0 = mergeText . go text0
  where
    go remaining [] = [NText remaining | not (T.null remaining)]
    go remaining ((native, display) : mentions) =
      let (before, match) = T.breakOn display remaining
       in if T.null match
            then go remaining mentions
            else
              [NText before | not (T.null before)]
                <> [NMention (NativeUserId native) display]
                <> go (T.drop (T.length display) match) mentions

matrixMediaKind :: Text -> MediaKind
matrixMediaKind = \case
  "m.image" -> MImage
  "m.video" -> MVideo
  "m.audio" -> MAudio
  _ -> MFile

relationFrom :: Value -> [MessageRelation]
relationFrom value = fromMaybe [] (parseMaybe parser value)
  where
    parser = withObject "relations" $ \o -> do
      relates <- o .:? "m.relates_to" .!= Object mempty
      withObject
        "m.relates_to"
        ( \r -> do
            relType <- r .:? "rel_type" :: Parser (Maybe Text)
            event <- r .:? "event_id"
            key <- r .:? "key"
            reply <- r .:? "m.in_reply_to" .!= Object mempty
            replyEvent <- withObject "m.in_reply_to" (.:? "event_id") reply
            pure $
              catMaybes
                [ ReplyTo . NativeEventId <$> replyEvent,
                  case (relType, event) of
                    (Just "m.replace", Just target) -> Just (Replaces (NativeEventId target))
                    (Just "m.annotation", Just target) -> Just (ReactsTo (NativeEventId target) (fromMaybe "" key))
                    _ -> Nothing
                ]
        )
        relates

mentionsFrom :: Value -> [NativeUserId]
mentionsFrom value = fromMaybe [] (parseMaybe parser value)
  where
    parser = withObject "mentions" $ \o -> do
      mentions <- o .:? "m.mentions" .!= Object mempty
      withObject "m.mentions" (\m -> fmap NativeUserId <$> (m .:? "user_ids" .!= [])) mentions

hydrateMatrixContent ::
  (Blob :> es, Log :> es, IOE :> es) =>
  HttpRuntime ->
  MatrixConfig ->
  MatrixEvent ->
  Eff es [Node 'Ingest]
hydrateMatrixContent runtime cfg event = traverse hydrate event.content
  where
    hydrate node@(NMedia (Just ref) meta)
      | Just mxc <- mediaRefRemoteUrl ref,
        "mxc://" `T.isPrefixOf` mxc = do
          downloaded <- liftIO (fetchMatrixMedia runtime cfg mxc)
          case downloaded of
            Left err -> do
              logAttention "Matrix media import failed; text remains durable" $
                object ["event_id" .= event.eventId, "mxc" .= mxc, "error" .= err]
              pure node
            Right bytes -> do
              when (matrixMediaSizeDrift meta.sizeBytes (BS.length bytes)) $
                logAttention "Matrix media size metadata drift; imported bounded response" $
                  object
                    [ "event_id" .= event.eventId,
                      "mxc" .= mxc,
                      "declared_size" .= meta.sizeBytes,
                      "actual_size" .= BS.length bytes
                    ]
              blob <- putBlob bytes
              let sha = blobRefSha256 blob
              pure $
                NMedia
                  (mediaBlobRef sha)
                  MediaMeta
                    { kind = meta.kind,
                      mime = meta.mime,
                      sizeBytes = Just (fromIntegral (BS.length bytes)),
                      name = meta.name,
                      description = meta.description,
                      raw = meta.raw
                    }
    hydrate node = pure node

fetchMatrixMedia ::
  HttpRuntime ->
  MatrixConfig ->
  Text ->
  IO (Either Text BS.ByteString)
fetchMatrixMedia runtime cfg mxc = case parseMxc mxc of
  Nothing -> pure (Left "invalid mxc URI")
  Just (serverName, mediaId) -> do
    let path =
          "/_matrix/client/v1/media/download/"
            <> pathPiece serverName
            <> "/"
            <> pathPiece mediaId
        url = T.dropWhileEnd (== '/') cfg.homeserver <> path
    parseRequestEither (T.unpack url) >>= \case
      Left failure -> pure (Left (renderTransportFailure failure))
      Right request0 -> do
        let request =
              request0
                { HTTP.requestHeaders = [("Authorization", "Bearer " <> TE.encodeUtf8 cfg.accessToken)],
                  HTTP.responseTimeout = HTTP.responseTimeoutMicro matrixHttpTimeoutMicros
                }
        runBuffered runtime StandardPool matrixMaxMediaBytes matrixStatusPreviewBytes request >>= \case
          Left (HttpStatusFailure status _ preview _) ->
            pure (Left ("Matrix media HTTP " <> T.pack (show status) <> ": " <> T.take 500 (TE.decodeUtf8Lenient preview)))
          Left failure -> pure (Left (renderTransportFailure failure))
          Right response -> pure (Right response.body)

-- | Matrix event size is advisory metadata. Homeservers can return the same
-- valid media with container/metadata differences, while runBuffered remains
-- the actual security boundary for response size.
matrixMediaSizeDrift :: Maybe Int64 -> Int -> Bool
matrixMediaSizeDrift expected actual = maybe False (/= fromIntegral actual) expected

parseMxc :: Text -> Maybe (Text, Text)
parseMxc value = case T.breakOn "/" (T.drop (T.length ("mxc://" :: Text)) value) of
  (serverName, rest)
    | "mxc://" `T.isPrefixOf` value,
      not (T.null serverName),
      not (T.null (T.drop 1 rest)) ->
        Just (serverName, T.drop 1 rest)
  _ -> Nothing

matrixRequest ::
  HttpRuntime ->
  MatrixConfig ->
  BS.ByteString ->
  Text ->
  [(Text, Text)] ->
  Maybe Value ->
  IO (Either Text Value)
matrixRequest runtime cfg method path params payload = do
  let url = T.dropWhileEnd (== '/') cfg.homeserver <> path <> queryText params
  parseRequestEither (T.unpack url) >>= \case
    Left failure -> pure (Left (renderTransportFailure failure))
    Right request0 -> do
      let request =
            request0
              { HTTP.method = method,
                HTTP.requestHeaders =
                  [ ("Authorization", "Bearer " <> TE.encodeUtf8 cfg.accessToken),
                    ("Content-Type", "application/json")
                  ],
                HTTP.requestBody = maybe (HTTP.RequestBodyBS "") (HTTP.RequestBodyLBS . encode) payload,
                HTTP.responseTimeout = HTTP.responseTimeoutMicro matrixHttpTimeoutMicros
              }
      runBuffered runtime StandardPool matrixMaxResponseBytes matrixStatusPreviewBytes request >>= \case
        Left (HttpStatusFailure status _ preview _) ->
          pure (Left ("Matrix HTTP " <> T.pack (show status) <> ": " <> T.take 500 (TE.decodeUtf8Lenient preview)))
        Left failure -> pure (Left (renderTransportFailure failure))
        Right response -> case eitherDecodeStrict' response.body of
          Left err -> pure (Left ("Matrix JSON: " <> T.pack err))
          Right value -> pure (Right value)

queryText :: [(Text, Text)] -> Text
queryText [] = ""
queryText queryPairs =
  "?" <> T.intercalate "&" [encoded key <> "=" <> encoded value | (key, value) <- queryPairs]
  where
    encoded = TE.decodeUtf8 . urlEncode True . TE.encodeUtf8

pathPiece :: Text -> Text
pathPiece = TE.decodeUtf8 . urlEncode True . TE.encodeUtf8

matrixFilter :: Text -> Text
matrixFilter room =
  TE.decodeUtf8 . LBS.toStrict . encode $
    object
      [ "room"
          .= object
            [ "rooms" .= [room],
              "timeline"
                .= object
                  [ "types"
                      .= [ "m.room.message" :: Text,
                           "m.reaction",
                           "m.room.redaction"
                         ],
                    "limit" .= (100 :: Int)
                  ]
            ],
        "presence" .= object ["types" .= ([] :: [Text])]
      ]

cursorText :: CursorRecord -> Maybe Text
cursorText record = case record.cursor of
  PlatformCursor (String token) -> Just token
  _ -> Nothing

matrixSourceFingerprint :: MatrixConfig -> Text
matrixSourceFingerprint cfg = T.dropWhileEnd (== '/') cfg.homeserver <> "|" <> cfg.userId

nonEmpty :: Text -> Maybe Text
nonEmpty value
  | T.null (T.strip value) = Nothing
  | otherwise = Just value

matrixStreamKey :: Text
matrixStreamKey = "sync"

matrixFailureBackoffMicros :: Int
matrixFailureBackoffMicros = 2_000_000

matrixHttpTimeoutMicros :: Int
matrixHttpTimeoutMicros = 150_000_000

matrixMaxResponseBytes :: Int
matrixMaxResponseBytes = 16 * 1024 * 1024

matrixMaxMediaBytes :: Int
matrixMaxMediaBytes = 64 * 1024 * 1024

matrixStatusPreviewBytes :: Int
matrixStatusPreviewBytes = 4096

maxGapPages :: Int
maxGapPages = 1000

first :: (a -> c) -> Either a b -> Either c b
first f = \case
  Left err -> Left (f err)
  Right value -> Right value
