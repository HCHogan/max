-- | Current-process delivery with one sequential lane per platform. Lanes run
-- concurrently so a slow transport does not block another platform.
-- Resolve identities/media and lower canonical IR before invoking adapters;
-- adapters encode native nodes and do not choose degradation policy.
module Max.Platform.Delivery
  ( DeliveryAttempt (..),
    DeliveryOperation (..),
    DeliveryTransport (..),
    DeliveryMedia (..),
    deliveryWorker,
    oneBotDeliveryTransport,
    loadDeliveryMedia,
    resolveDeliveryMedia,
    mediaTextCaps,
    loweredText,
    oneBotNodes,
    oneBotReplySegment,
    oneBotReactionAction,
    fanOutMediaChunks,
    toCompletion,
    deliveryAttemptBudget,
  )
where

import Control.Monad (forever)
import Data.Aeson (Result (..), fromJSON, toJSON)
import Data.ByteString qualified as BS
import Data.ByteString.Base64 qualified as B64
import Data.Either (fromRight)
import Data.Int (Int64)
import Data.List (find, nub)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (NominalDiffTime, addUTCTime, getCurrentTime)
import Effectful
import Effectful.Concurrent.Async (Concurrent, forConcurrently_)
import Effectful.Exception (SomeException)
import Effectful.Log
import Effectful.PostgreSQL (WithConnection)
import Max.Effects.Blob (Blob, blobRefFromSha256, readBlob)
import Max.HttpRuntime
  ( BufferedResponse (body),
    HttpPool (LegacyEmsPool, StandardPool),
    HttpRuntime,
    TransportFailure (TlsFailed),
    parseRequestEither,
    renderTransportFailure,
    runBuffered,
  )
import Max.IR
import Max.IR.Digest (digest)
import Max.IR.Lower
import Max.Platform (PlatformBackend (..))
import Max.Platform.Delivery.Parts
import Max.Platform.Delivery.Queue
import Max.Platform.Delivery.Store
import Max.Platform.Store
  ( DeliveryCompletion (..),
    DeliveryRequest (..),
    DeliveryTarget (..),
    completeDelivery,
    deliveryMentionNatives,
    loadDelivery,
    startDelivery,
  )
import Max.Platform.Types
  ( EventKind (..),
    NativeEventId (..),
    NativeUserId (..),
    Platform (..),
    ReactionAction (..),
    renderPlatform,
  )
import Max.Util (catchSync, readIntegral, trySync, trySyncIO, withBinaryTempFile)
import OneBot.Action (Action (SetMsgEmojiLike, UploadGroupFile, UploadPrivateFile), Response (..), extractOutMid, sendChatMsg)
import OneBot.Segment (Segment (..), imageSeg, stickerSeg)
import OneBot.Types (GroupId (..), MessageId (..), UserId (..), isPrivateChat, privateChatUserId)
import System.Directory (createDirectoryIfMissing)
import System.FilePath (takeFileName)
import System.IO (hClose)
import System.Posix.Files (setFileMode)

data DeliveryOperation
  = DeliverMessage !LoweredMessage
  | DeliverEdit !NativeEventId !LoweredMessage
  | DeliverReaction !NativeEventId !Text !ReactionAction !(Maybe NativeEventId)
  | DeliverRedaction !NativeEventId
  deriving stock (Eq, Show)

data DeliveryTransport = DeliveryTransport
  { platform :: !Platform,
    deliver :: !(PartJournal -> DeliveryRequest -> DeliveryOperation -> IO DeliveryAttempt)
  }

-- | What the native media tier resolved to, plus the audit trail for what it
-- could not resolve.  A reference the store cannot produce bytes for is
-- absent from 'resolved', which is exactly how the shared lowerer already
-- spells "sourceless": that node folds to its text tier.
data DeliveryMedia = DeliveryMedia
  { resolved :: ![(MediaRef, ResolvedMedia)],
    notes :: ![LowerNote]
  }
  deriving stock (Eq, Show)

-- | Resolve only media that can survive lowering's native tier and budget.
--
-- Size-integrity violations are deterministic poison: the canonical body
-- promises bytes the endpoint must not be handed, and the worker marks the
-- delivery permanently failed.  A blob the store cannot read is a different
-- fact — the message is sourceless, not oversized (ADR 003 §2), so it folds
-- to the text tier here and the message's text still goes out.
loadDeliveryMedia ::
  (Blob :> es) =>
  OutboundCaps ->
  Body 'Canonical ->
  Eff es DeliveryMedia
loadDeliveryMedia caps body = go (max 0 caps.maxNativeMedia) [] [] 0 candidates
  where
    candidates = mapMaybe nativeSource body.nodes
    nativeSource = \case
      NMedia (Just ref) meta | mediaTier caps meta.kind == TierNative -> Just (ref, meta.sizeBytes)
      _ -> Nothing
    go remaining resolved notes total pending
      | remaining <= 0 = pure DeliveryMedia {resolved = reverse resolved, notes = reverse notes}
      | otherwise = case pending of
          [] -> pure DeliveryMedia {resolved = reverse resolved, notes = reverse notes}
          candidate@(ref, _) : rest
            | Just _ <- lookup ref resolved -> go (remaining - 1) resolved notes total rest
            | otherwise ->
                loadOne candidate >>= \case
                  Left note -> go remaining resolved (note : notes) total rest
                  Right value@(_, payload) -> do
                    let bytes = case payload of ResolvedBytes bs -> BS.length bs; ResolvedUrl _ -> 0
                    if total + bytes > deliveryMediaTotalBytes
                      then error "canonical delivery media exceeds total byte limit"
                      else go (remaining - 1) (value : resolved) notes (total + bytes) rest

    loadOne (ref, declaredSize) = case mediaRefBlobSha ref of
      Nothing -> pure (Right (ref, ResolvedUrl (renderMediaRef ref)))
      Just sha -> case blobRefFromSha256 sha of
        Nothing -> pure (Left (unresolvable ref "invalid blob reference"))
        Just blobRef ->
          trySync (readBlob blobRef) >>= \case
            Left e -> pure (Left (unresolvable ref (T.pack (show (e :: SomeException)))))
            Right payload -> do
              let actual = BS.length payload
              if actual > deliveryMediaItemBytes
                then error "canonical delivery media exceeds per-item byte limit"
                else case declaredSize of
                  Just expected
                    | expected /= fromIntegral actual ->
                        error "canonical delivery media size changed"
                  _ -> pure (Right (ref, ResolvedBytes payload))

    unresolvable ref detail =
      LowerNote "media_source" NoteFolded (Just (renderMediaRef ref <> ": " <> detail))

-- | Produce the bytes an upload-style transport must hand its platform.
-- Blob-backed media already carries them; a remote URL is fetched once,
-- bounded by the caller's own attachment limit and checked against the size
-- the canonical body declared.  Matrix and iMessage both upload before they
-- send, and a private copy of this in each adapter was one edit away from
-- disagreeing about that size check.
resolveDeliveryMedia ::
  HttpRuntime ->
  -- | attachment byte ceiling
  Int ->
  -- | diagnostic preview bytes for a failing status
  Int ->
  ResolvedMedia ->
  -- | size the canonical body declared, when it declared one
  Maybe Int64 ->
  IO (Either Text BS.ByteString)
resolveDeliveryMedia _ _ _ (ResolvedBytes bytes) _ = pure (Right bytes)
resolveDeliveryMedia runtime maxBytes previewBytes (ResolvedUrl sourceUrl) declaredSize
  | "http://" `T.isPrefixOf` sourceUrl || "https://" `T.isPrefixOf` sourceUrl =
      parseRequestEither (T.unpack sourceUrl) >>= \case
        Left failure -> pure (Left (renderTransportFailure failure))
        Right request -> do
          first <- runBuffered runtime StandardPool maxBytes previewBytes request
          -- Tencent's file CDN never implemented RFC 7627, so a current TLS
          -- stack refuses the handshake outright and a mirrored file went out
          -- as a bare CDN link.  The image fetch worker has always reached
          -- those hosts through the legacy pool; this path simply never did.
          -- The concession stays earned rather than assumed: only a proven
          -- handshake failure downgrades, and only for that one request.
          settled <- case first of
            Left (TlsFailed _) -> runBuffered runtime LegacyEmsPool maxBytes previewBytes request
            other -> pure other
          pure $ case settled of
            Left failure -> Left (renderTransportFailure failure)
            Right response
              | maybe False (/= fromIntegral (BS.length response.body)) declaredSize ->
                  Left "delivery media size changed"
              | otherwise -> Right response.body
  | otherwise = pure (Left "delivery media has no transferable source")

deliveryWorker ::
  (Blob :> es, WithConnection :> es, Log :> es, Concurrent :> es, IOE :> es) =>
  DeliveryQueue -> [DeliveryTransport] -> Eff es ()
deliveryWorker queue transports = localDomain "delivery" $
  forConcurrently_ lanes $ \(name, serves) -> localData [("lane", toJSON name)] $ forever $ do
    work <- liftIO (nextDelivery queue serves)
    deliverQueued work `catchSync` \err -> do
      now <- liftIO getCurrentTime
      let completion = DeliveryUnknown (T.pack (show err)) now
      _ <- trySync (completeDelivery work.target.deliveryId [] completion)
      liftIO (settleDelivery queue work.target.deliveryId completion)
      logAttention "delivery failed; not replayed" (object ["delivery_id" .= work.target.deliveryId, "error" .= show err])
  where
    served = nub [transport.platform | transport <- transports]
    lanes =
      [(renderPlatform platform, (== platform)) | platform <- served]
        <> [("unrouted", (`notElem` served))]

    deliverQueued work = do
      loaded <- loadDelivery work.target.deliveryId
      case loaded of
        Nothing -> do
          let completion = DeliverySuppressedAs "endpoint unavailable"
          _ <- completeDelivery work.target.deliveryId [] completion
          liftIO (settleDelivery queue work.target.deliveryId completion)
        Just stored -> do
          let request = stored {attemptCount = work.attempt}
          started <- startDelivery request.deliveryId request.attemptCount
          if not started
            then liftIO (settleDelivery queue request.deliveryId (DeliverySuppressedAs "receipt already settled"))
            else do
              (completion, lowerNotes) <- withEffToIO (ConcUnlift Ephemeral Unlimited) $ \run ->
                let journal =
                      PartJournal
                        { plan = run . planDeliveryParts request,
                          begin = \safety index -> run (beginDeliveryPart request safety index),
                          finish = \index attempt -> run (finishDeliveryPart request index attempt)
                        }
                 in run (liftIO getCurrentTime >>= \now -> routeDelivery journal now request)
              recorded <- completeDelivery request.deliveryId lowerNotes completion
              liftIO (settleDelivery queue request.deliveryId completion)
              logInfo "delivery settled" $
                object
                  [ "delivery_id" .= request.deliveryId,
                    "recorded" .= recorded,
                    "outcome" .= completionName completion,
                    "lower_notes" .= toJSON lowerNotes
                  ]

    routeDelivery journal now request = case request.eventKind of
      EventMessage -> withTransport request $ \transport -> deliverContent journal now request transport DeliverMessage
      EventEdit
        | not request.capabilities.edit -> pure (DeliverySuppressedAs "edit unsupported", [])
        | Just target <- request.actionTarget ->
            withTransport request $ \transport ->
              deliverContent journal now request transport (DeliverEdit target)
        | otherwise -> pure (DeliveryPermanentlyFailed "edit target has no native copy", [])
      EventReaction
        | not request.capabilities.reaction -> pure (DeliverySuppressedAs "reaction unsupported", [])
        | Just target <- request.actionTarget,
          Just key <- request.reactionKey ->
            withTransport request $ \transport -> do
              attempt <-
                runTransport
                  journal
                  transport
                  request
                  (DeliverReaction target key request.reactionAction request.previousReactionNative)
              pure (toCompletion request.attemptCount now attempt, [])
        | otherwise -> pure (DeliveryPermanentlyFailed "reaction target or key is missing", [])
      EventRedaction
        | not request.capabilities.redact -> pure (DeliverySuppressedAs "redaction unsupported", [])
        | Just target <- request.actionTarget ->
            withTransport request $ \transport -> do
              attempt <- runTransport journal transport request (DeliverRedaction target)
              pure (toCompletion request.attemptCount now attempt, [])
        | otherwise -> pure (DeliveryPermanentlyFailed "redaction target has no native copy", [])
      EventMembership -> pure (DeliverySuppressedAs "membership events are not delivered", [])

    withTransport request act = case find ((== request.platform) . (.platform)) transports of
      Nothing ->
        pure
          ( DeliveryPermanentlyFailed ("no transport registered for " <> renderPlatform request.platform),
            []
          )
      Just transport -> act transport

    deliverContent journal now request transport operation = do
      nativeMentions <-
        deliveryMentionNatives request.endpointId (mentionIdentities request.body)
      mediaResult <- trySync (loadDeliveryMedia request.capabilities request.body)
      let media = fromRight DeliveryMedia {resolved = [], notes = []} mediaResult
          lowerWith caps resolved =
            lower
              LowerEnv
                { platform = request.platform,
                  caps,
                  attribution = request.attribution,
                  mentionNative = (`Map.lookup` nativeMentions),
                  mediaResolve = (`lookup` resolved),
                  replyTarget = if request.eventKind == EventMessage then request.replyContext else Nothing
                }
              request.body
          lowered = lowerWith request.capabilities media.resolved
          loweredNotes = lowered.notes <> media.notes
      case mediaResult of
        Left e ->
          pure
            ( DeliveryPermanentlyFailed
                ("media load failed: " <> T.pack (show (e :: SomeException))),
              loweredNotes
            )
        Right _
          | null lowered.chunks -> pure (DeliverySuppressedAs "lowering produced no output", loweredNotes)
          | otherwise -> do
              attempt <- runTransport journal transport request (operation lowered)
              case attempt of
                AttemptMediaFallback err -> do
                  let relowered = lowerWith (mediaTextCaps request.capabilities) []
                      fallbackNote = LowerNote "media_emit" NoteFolded (Just err)
                      fallbackNotes = relowered.notes <> media.notes <> [fallbackNote]
                  if null relowered.chunks
                    then pure (DeliverySuppressedAs "media fallback produced no output", fallbackNotes)
                    else do
                      logLowered request "delivery lowered after media failure" relowered fallbackNotes
                      secondAttempt <- runTransport journal transport request (operation relowered)
                      let completion' = case secondAttempt of
                            AttemptMediaFallback err' -> DeliveryPermanentlyFailed ("media fallback loop: " <> err')
                            other -> toCompletion request.attemptCount now other
                      pure (completion', fallbackNotes)
                other -> do
                  logLowered request "delivery lowered" lowered loweredNotes
                  pure (toCompletion request.attemptCount now other, loweredNotes)

    logLowered request message lowered notes =
      logInfo message $
        object
          [ "delivery_id" .= request.deliveryId,
            "canonical_message_id" .= request.canonicalMessageId,
            "platform" .= renderPlatform request.platform,
            "chunks" .= map (digest . Body) lowered.chunks,
            "lower_notes" .= toJSON notes
          ]

    runTransport journal transport request operation =
      liftIO (trySyncIO (transport.deliver journal request operation)) >>= \case
        Left e ->
          pure
            ( AttemptOutcomeUnknown
                ("transport exception: " <> T.pack (show (e :: SomeException)))
            )
        Right attempt -> pure attempt

-- | Bound confirmed rejections so one undeliverable message cannot block the lane.
-- Ambiguous sends stop immediately as @outcome_unknown@; unreachable transports
-- use the separate 'AttemptRetryable' policy (ADR 003 §7).
toCompletion :: Int -> UTCTime -> DeliveryAttempt -> DeliveryCompletion
toCompletion attempts now = \case
  AttemptConfirmed native -> DeliveryConfirmedAs native
  AttemptAccepted native -> DeliveryAccepted native
  AttemptRetryable err -> DeliveryRetry err (addUTCTime (retryDelay attempts) now)
  AttemptRejected err
    | attempts >= deliveryAttemptBudget ->
        DeliveryPermanentlyFailed
          ( "retry budget exhausted after "
              <> T.pack (show attempts)
              <> " attempts: "
              <> err
          )
    | otherwise -> DeliveryRetry err (addUTCTime (retryDelay attempts) now)
  AttemptOutcomeUnknown err -> DeliveryUnknown err now
  AttemptPermanentlyFailed err -> DeliveryPermanentlyFailed err
  AttemptSuppressed reason -> DeliverySuppressedAs reason
  AttemptMediaFallback err -> DeliveryPermanentlyFailed ("unhandled media fallback: " <> err)

-- | Force every native media tier to its total text fallback while preserving
-- an explicitly configured drop. Used only after an adapter proves that no
-- message was emitted during native media preparation.
mediaTextCaps :: OutboundCaps -> OutboundCaps
mediaTextCaps caps =
  caps
    { image = textUnlessDrop caps.image,
      sticker = textUnlessDrop caps.sticker,
      video = textUnlessDrop caps.video,
      audio = textUnlessDrop caps.audio,
      file = textUnlessDrop caps.file,
      maxNativeMedia = 0
    }
  where
    textUnlessDrop TierDrop = TierDrop
    textUnlessDrop _ = TierText

-- | Upload-style transports publish at most one native attachment per wire
-- event.  Preserve canonical node order by splitting a lowered chunk
-- immediately before its second and later media nodes; intervening text stays
-- after the media it followed.  The first wire chunk alone receives reply
-- provenance in the adapters.
fanOutMediaChunks :: [[Node 'Lowered]] -> [[Node 'Lowered]]
fanOutMediaChunks = concatMap splitChunk
  where
    splitChunk = go [] False
    go acc _ [] = [reverse acc | not (null acc)]
    go acc hasMedia (node : rest) = case node of
      NMedia {}
        | hasMedia -> reverse acc : go [node] True rest
        | otherwise -> go (node : acc) True rest
      _ -> go (node : acc) hasMedia rest

completionName :: DeliveryCompletion -> Text
completionName = \case
  DeliveryConfirmedAs {} -> "confirmed"
  DeliveryAccepted {} -> "accepted_unconfirmed"
  DeliveryRetry {} -> "retry"
  DeliveryUnknown {} -> "outcome_unknown"
  DeliveryPermanentlyFailed {} -> "permanent_failure"
  DeliverySuppressedAs {} -> "suppressed"

-- | Emit OneBot nodes exactly as lowered.  Unsupported native node kinds are
-- contract violations and fail the delivery; no fallback is chosen here.
oneBotNodes :: [Node 'Lowered] -> Either Text [Segment]
oneBotNodes = traverse emit
  where
    emit = \case
      NText body -> Right (SegText body)
      NMention (NativeUserId native) _ ->
        maybe (Left ("invalid OneBot mention id " <> native)) (Right . SegAt . UserId) (readIntegral native)
      NEmote emote -> case emote.raw >>= rawSegment of
        Just face@SegFace {} -> Right face
        _ -> maybe (Left ("invalid OneBot emote id " <> emote.nativeId)) (\n -> Right (SegFace n emote.name)) (readIntegral emote.nativeId)
      NMedia payload meta -> case meta.kind of
        MImage -> Right (imageSeg (mediaPayload payload))
        MSticker -> Right (stickerSeg (mediaPayload payload))
        other -> Left ("unsupported native OneBot media kind " <> mediaKindText other)
      NCard card -> case card.raw >>= rawSegment of
        Just native@SegCard {} -> Right native
        _ -> Left "native OneBot card lacks a valid raw segment"

    rawSegment value = case fromJSON value of
      Success segment -> Just segment
      Error _ -> Nothing

mediaPayload :: ResolvedMedia -> Text
mediaPayload = \case
  ResolvedBytes payload -> "base64://" <> TE.decodeUtf8 (B64.encode payload)
  ResolvedUrl url -> url

-- | Textual wire body for transports that natively encode mentions beside
-- their visible @display and attachments outside the body.  Any other native
-- structure is rejected instead of being degraded in the adapter.
loweredText :: [Node 'Lowered] -> Either Text Text
loweredText = fmap T.concat . traverse emit
  where
    emit :: Node 'Lowered -> Either Text Text
    emit = \case
      NText body -> Right body
      NMention _ display -> Right (mentionToken display)
      NMedia {} -> Right ""
      NEmote {} -> Left "text emitter received a native emote"
      NCard {} -> Left "text emitter received a native card"

-- | Adapter for OneBot-shaped edge transports.  Each lowered chunk is one
-- send. Successful parts retain their receipts; uncertain parts park until
-- reconciled because the OneBot edge cannot deduplicate a replay.
oneBotDeliveryTransport :: HttpRuntime -> Platform -> PlatformBackend -> DeliveryTransport
oneBotDeliveryTransport runtime platform backend =
  DeliveryTransport
    { platform,
      deliver = \journal claim -> \case
        DeliverMessage lowered -> sendChunks journal claim lowered
        DeliverReaction target key action _ -> sendReaction target key action
        DeliverEdit {} -> pure (AttemptPermanentlyFailed "OneBot endpoint advertised edit without an emitter")
        DeliverRedaction {} -> pure (AttemptPermanentlyFailed "OneBot endpoint advertised redaction without an emitter")
    }
  where
    sendChunks journal claim lowered = do
      let chunks = concatMap splitFiles lowered.chunks
          prepare index chunk = case chunk of
            [NMedia payload meta]
              | meta.kind == MFile && platform == PlatformQQ ->
                  resolveDeliveryMedia runtime deliveryMediaItemBytes 2048 payload meta.sizeBytes >>= \case
                    Left err -> pure (Left (AttemptMediaFallback err))
                    Right bytes -> pure (Right (Left (bytes, fromMaybe "artifact" meta.name)))
            _ -> pure $ case (,) <$> oneBotNodes chunk <*> oneBotReplySegment index lowered.replyNative of
              Left err -> Left (AttemptPermanentlyFailed err)
              Right (body, reply) -> Right (Right (reply <> body))
      prepareParts prepare chunks >>= \case
        Left err -> pure err
        Right payloads -> runDeliveryParts
          journal
          NonIdempotentParts
          AttemptAccepted
          [wireFingerprint (if i == 0 then lowered.replyNative else Nothing) chunk | (i, chunk) <- zip [0 :: Int ..] chunks]
          payloads
          $ \_ payload -> do
            let gid = GroupId claim.compatibilityConversationId
            response <- case payload of
              Right body -> backend.pbCall (sendChatMsg gid body) oneBotTimeoutMs
              Left (bytes, name) -> withQQFile bytes $ \path ->
                backend.pbCall (if isPrivateChat gid then UploadPrivateFile (privateChatUserId gid) path name else UploadGroupFile gid path name) 60000
            pure $ case response of
              Left err
                | failedBeforeEffect err -> AttemptRetryable err
                | otherwise -> AttemptOutcomeUnknown err
              Right (Response _ retcode value _)
                | retcode /= 0 -> AttemptRejected ("retcode " <> T.pack (show retcode))
                | otherwise -> AttemptAccepted (NativeEventId . T.pack . show <$> extractOutMid value)

    -- QQ files are file-library uploads, each its own wire part. Other nodes
    -- retain their order and the existing multi-image message behavior.
    splitFiles [] = []
    splitFiles (node@(NMedia _ meta) : rest) | meta.kind == MFile = [node] : splitFiles rest
    splitFiles nodes = let (prefix, rest) = break isFile nodes in prefix : splitFiles rest
    isFile (NMedia _ meta) = meta.kind == MFile
    isFile _ = False

    -- This mount is an edge concern. Canonical publishers never know NapCat
    -- paths; files exist here only for the duration of one bounded upload.
    withQQFile bytes action = do
      createDirectoryIfMissing True "var/outbox"
      withBinaryTempFile "var/outbox" "qq-artifact" $ \path handle -> do
        BS.hPut handle bytes
        hClose handle
        -- The setgid outbox directory assigns the dedicated max-outbox group.
        -- Native NapCat gets read access only to this short-lived upload file.
        setFileMode path 0o640
        action (T.pack ("/data/outbox/" <> takeFileName path))

    sendReaction (NativeEventId target) key action =
      case oneBotReactionAction (NativeEventId target) key action of
        Just reaction ->
          backend.pbCall reaction oneBotTimeoutMs >>= \case
            Left err -> pure (AttemptRetryable err)
            Right (Response _ retcode _ _)
              | retcode == 0 -> pure (AttemptConfirmed Nothing)
              -- A reaction whose target was deleted refuses forever, and it
              -- would otherwise hold every later copy on this endpoint.
              | otherwise -> pure (AttemptRejected ("retcode " <> T.pack (show retcode)))
        Nothing -> pure (AttemptSuppressed "reaction is not a QQ face id or target")

oneBotReactionAction :: NativeEventId -> Text -> ReactionAction -> Maybe Action
oneBotReactionAction (NativeEventId target) key action =
  SetMsgEmojiLike . MessageId
    <$> readIntegral target
    <*> readIntegral key
    <*> pure (action == ReactionAdd)

oneBotReplySegment :: Int -> Maybe NativeEventId -> Either Text [Segment]
oneBotReplySegment index native
  | index /= 0 = Right []
  | otherwise = case native of
      Nothing -> Right []
      Just (NativeEventId raw) ->
        maybe (Left ("invalid OneBot reply id " <> raw)) (Right . pure . SegReply . MessageId) (readIntegral raw)

failedBeforeEffect :: Text -> Bool
failedBeforeEffect err =
  any (`T.isInfixOf` T.toLower err) ["no client connected", "send failed"]

retryDelay :: Int -> NominalDiffTime
retryDelay attempts = fromIntegral (min (300 :: Int) (2 ^ min 8 (max 0 attempts)))

-- | How many attempts one /rejected/ delivery may spend before its
-- endpoint's ordered lane matters more than this copy.  With 'retryDelay'
-- that is 2+4+…+256 then 256s per attempt: roughly 45 minutes, long enough
-- for a transient refusal to clear and short enough that one poisoned row
-- cannot hold the conversation hostage.  An unreachable edge is not budgeted
-- at all, so this never truncates an outage backlog.
deliveryAttemptBudget :: Int
deliveryAttemptBudget = 16

oneBotTimeoutMs :: Int
oneBotTimeoutMs = 30000

deliveryMediaItemBytes :: Int
deliveryMediaItemBytes = 64 * 1024 * 1024

deliveryMediaTotalBytes :: Int
deliveryMediaTotalBytes = 64 * 1024 * 1024
