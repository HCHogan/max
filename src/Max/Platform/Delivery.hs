-- | Durable per-endpoint delivery worker and emit-only transport seam.
--
-- A claim contains only the stored canonical IR and endpoint facts.  The
-- worker resolves destination identities and media, calls the one shared
-- capability-driven lowering function, persists its audit notes, and hands
-- the resulting 'LoweredMessage' to an adapter.  Adapters may encode native
-- nodes; they never read prompt projections or choose degradation policy.
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

import Control.Applicative ((<|>))
import Control.Monad (forM_)
import Data.Aeson (Result (..), fromJSON, toJSON)
import Data.ByteString qualified as BS
import Data.ByteString.Base64 qualified as B64
import Data.Either (fromRight, lefts, rights)
import Data.Int (Int64)
import Data.List (find, nubBy)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (NominalDiffTime, addUTCTime, getCurrentTime)
import Effectful
import Effectful.Exception (SomeException)
import Effectful.Log
import Effectful.PostgreSQL (WithConnection)
import Max.DB.Notify (WorkChannel (DeliveryWork), claimOrWait)
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
import Max.Platform.Store
  ( DeliveryClaim (..),
    DeliveryCompletion (..),
    claimDeliveries,
    completeDelivery,
    deliveryMentionNatives,
    startDelivery,
  )
import Max.Platform.Types
  ( EventKind (..),
    NativeEventId (..),
    NativeUserId (..),
    Platform,
    ReactionAction (..),
    renderPlatform,
  )
import Max.Util (readIntegral, trySync, trySyncIO)
import OneBot.Action (Action (SetMsgEmojiLike), Response (..), extractOutMid, sendChatMsg)
import OneBot.Segment (Segment (..), imageSeg, stickerSeg)
import OneBot.Types (GroupId (..), MessageId (..), UserId (..))

data DeliveryAttempt
  = AttemptConfirmed !(Maybe NativeEventId)
  | AttemptAccepted !(Maybe NativeEventId)
  | -- | The edge could not be reached and provably had no effect.  Retried
    -- without a bound: while it is down nothing else can be delivered to this
    -- endpoint either, so waiting denies the ordered lane to no one.  A real
    -- QQ edge outage took 159 attempts over eleven hours and then delivered.
    AttemptRetryable !Text
  | -- | A reachable edge refused this content (QQ risk control, a reaction on
    -- a deleted target).  Rejections can be transient, so it is retried — but
    -- the endpoint is demonstrably working, so the lane must not wait on it
    -- forever; 'deliveryAttemptBudget' ends it.
    AttemptRejected !Text
  | AttemptOutcomeUnknown !Text
  | AttemptPermanentlyFailed !Text
  | AttemptSuppressed !Text
  | -- | Native media preparation failed before the adapter emitted any
    -- message. The worker may safely re-run the shared lowerer at text tier;
    -- adapters never construct that fallback themselves.
    AttemptMediaFallback !Text
  deriving stock (Eq, Show)

data DeliveryOperation
  = DeliverMessage !LoweredMessage
  | DeliverEdit !NativeEventId !LoweredMessage
  | DeliverReaction !NativeEventId !Text !ReactionAction !(Maybe NativeEventId)
  | DeliverRedaction !NativeEventId
  deriving stock (Eq, Show)

data DeliveryTransport = DeliveryTransport
  { platform :: !Platform,
    deliver :: !(DeliveryClaim -> DeliveryOperation -> IO DeliveryAttempt)
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
loadDeliveryMedia caps body = do
  loaded <- traverse loadOne candidates
  let resolved = rights loaded
      notes = lefts loaded
      totalBytes = sum [BS.length bytes | (_, ResolvedBytes bytes) <- resolved]
  if totalBytes > deliveryMediaTotalBytes
    then error "canonical delivery media exceeds total byte limit"
    else pure DeliveryMedia {resolved, notes}
  where
    candidates =
      nubBy (\(left, _) (right, _) -> left == right) . take (max 0 caps.maxNativeMedia) $
        mapMaybe nativeSource body.nodes

    nativeSource = \case
      NMedia (Just ref) meta
        | nativeMediaTier caps meta.kind == TierNative -> Just (ref, meta.sizeBytes)
      _ -> Nothing

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

nativeMediaTier :: OutboundCaps -> MediaKind -> Tier
nativeMediaTier caps = \case
  MImage -> caps.image
  MSticker -> caps.sticker
  MVideo -> caps.video
  MAudio -> caps.audio
  MFile -> caps.file

deliveryWorker ::
  (Blob :> es, WithConnection :> es, Log :> es, IOE :> es) =>
  Text ->
  [DeliveryTransport] ->
  Eff es ()
deliveryWorker workerId transports = localDomain "delivery" loop
  where
    loop = do
      claims <-
        claimOrWait DeliveryWork $
          claimDeliveries workerId deliveryBatchSize deliveryLeaseSeconds
      forM_ claims deliverClaim
      loop

    deliverClaim claim = do
      started <- startDelivery workerId claim.deliveryId claim.attemptCount deliveryLeaseSeconds
      if not started
        then
          logInfo "delivery reservation was no longer owned" $
            object ["delivery_id" .= claim.deliveryId, "worker" .= workerId]
        else do
          now <- liftIO getCurrentTime
          (completion, lowerNotes) <- routeClaim now claim
          completed <- completeDelivery workerId claim.deliveryId claim.attemptCount lowerNotes completion
          if completed
            then
              logInfo "delivery completed" $
                object
                  [ "delivery_id" .= claim.deliveryId,
                    "canonical_message_id" .= claim.canonicalMessageId,
                    "platform" .= renderPlatform claim.platform,
                    "outcome" .= completionName completion,
                    "lower_notes" .= toJSON lowerNotes
                  ]
            else
              logAttention "delivery lease lost before completion" $
                object ["delivery_id" .= claim.deliveryId, "worker" .= workerId]

    routeClaim now claim = case claim.eventKind of
      EventMessage -> withTransport claim $ \transport -> deliverContent now claim transport DeliverMessage
      EventEdit
        | not claim.capabilities.edit -> pure (DeliverySuppressedAs "edit unsupported", [])
        | Just target <- claim.actionTarget ->
            withTransport claim $ \transport ->
              deliverContent now claim transport (DeliverEdit target)
        | otherwise -> pure (DeliveryPermanentlyFailed "edit target has no native copy", [])
      EventReaction
        | not claim.capabilities.reaction -> pure (DeliverySuppressedAs "reaction unsupported", [])
        | Just target <- claim.actionTarget,
          Just key <- claim.reactionKey ->
            withTransport claim $ \transport -> do
              attempt <-
                runTransport
                  transport
                  claim
                  (DeliverReaction target key claim.reactionAction claim.previousReactionNative)
              pure (toCompletion claim.attemptCount now attempt, [])
        | otherwise -> pure (DeliveryPermanentlyFailed "reaction target or key is missing", [])
      EventRedaction
        | not claim.capabilities.redact -> pure (DeliverySuppressedAs "redaction unsupported", [])
        | Just target <- claim.actionTarget ->
            withTransport claim $ \transport -> do
              attempt <- runTransport transport claim (DeliverRedaction target)
              pure (toCompletion claim.attemptCount now attempt, [])
        | otherwise -> pure (DeliveryPermanentlyFailed "redaction target has no native copy", [])
      EventMembership -> pure (DeliverySuppressedAs "membership events are not delivered", [])

    withTransport claim act = case find ((== claim.platform) . (.platform)) transports of
      Nothing ->
        pure
          ( DeliveryPermanentlyFailed ("no transport registered for " <> renderPlatform claim.platform),
            []
          )
      Just transport -> act transport

    deliverContent now claim transport operation = do
      nativeMentions <-
        deliveryMentionNatives claim.endpointId (mentionIdentities claim.body)
      mediaResult <- trySync (loadDeliveryMedia claim.capabilities claim.body)
      let media = fromRight DeliveryMedia {resolved = [], notes = []} mediaResult
          lowerWith caps resolved =
            lower
              LowerEnv
                { platform = claim.platform,
                  caps,
                  attribution = claim.attribution,
                  mentionNative = (`Map.lookup` nativeMentions),
                  mediaResolve = (`lookup` resolved),
                  replyTarget = if claim.eventKind == EventMessage then claim.replyContext else Nothing
                }
              claim.body
          lowered = lowerWith claim.capabilities media.resolved
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
              attempt <- runTransport transport claim (operation lowered)
              case attempt of
                AttemptMediaFallback err -> do
                  let relowered = lowerWith (mediaTextCaps claim.capabilities) []
                      fallbackNote = LowerNote "media_emit" NoteFolded (Just err)
                      fallbackNotes = relowered.notes <> media.notes <> [fallbackNote]
                  if null relowered.chunks
                    then pure (DeliverySuppressedAs "media fallback produced no output", fallbackNotes)
                    else do
                      logLowered claim "delivery lowered after media failure" relowered fallbackNotes
                      secondAttempt <- runTransport transport claim (operation relowered)
                      let completion' = case secondAttempt of
                            AttemptMediaFallback err' -> DeliveryPermanentlyFailed ("media fallback loop: " <> err')
                            other -> toCompletion claim.attemptCount now other
                      pure (completion', fallbackNotes)
                other -> do
                  logLowered claim "delivery lowered" lowered loweredNotes
                  pure (toCompletion claim.attemptCount now other, loweredNotes)

    logLowered claim message lowered notes =
      logInfo message $
        object
          [ "delivery_id" .= claim.deliveryId,
            "canonical_message_id" .= claim.canonicalMessageId,
            "platform" .= renderPlatform claim.platform,
            "chunks" .= map (digest . Body) lowered.chunks,
            "lower_notes" .= toJSON notes
          ]

    runTransport transport claim operation =
      liftIO (trySyncIO (transport.deliver claim operation)) >>= \case
        Left e ->
          pure
            ( AttemptOutcomeUnknown
                ("transport exception: " <> T.pack (show (e :: SomeException)))
            )
        Right attempt -> pure attempt

-- | ADR 003 §7's attempt budget.  A rejection by a live edge is
-- retryable-shaped forever, and every retry re-blocks the endpoint's ordered
-- lane behind one row that will never land.  A rejection is only reported
-- once the transport has proved no message was emitted, so ending it is a
-- deterministic poison, not an undecidable outcome: the copy is permanently
-- failed and the lane releases.  Attempts that could have taken effect are
-- already terminal as @outcome_unknown@ on their first occurrence, and an
-- unreachable edge is deliberately unbounded — see 'AttemptRetryable'.
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
-- send, and no OneBot send is idempotent: once a chunk may have taken effect,
-- a later failure parks the delivery rather than retrying and duplicating the
-- prefix chunks.
oneBotDeliveryTransport :: Platform -> PlatformBackend -> DeliveryTransport
oneBotDeliveryTransport platform backend =
  DeliveryTransport
    { platform,
      deliver = \claim -> \case
        DeliverMessage lowered -> sendChunks claim lowered 0 False Nothing lowered.chunks
        DeliverReaction target key action _ -> sendReaction target key action
        DeliverEdit {} -> pure (AttemptPermanentlyFailed "OneBot endpoint advertised edit without an emitter")
        DeliverRedaction {} -> pure (AttemptPermanentlyFailed "OneBot endpoint advertised redaction without an emitter")
    }
  where
    sendChunks _ _ _ _ firstNative [] = pure (AttemptAccepted firstNative)
    sendChunks claim lowered index sentAny firstNative (chunk : rest) =
      case oneBotNodes chunk of
        Left err -> pure (AttemptPermanentlyFailed err)
        Right body -> case oneBotReplySegment index lowered.replyNative of
          Left err -> pure (AttemptPermanentlyFailed err)
          Right replyPrefix ->
            backend.pbCall (sendChatMsg (GroupId claim.compatibilityConversationId) (replyPrefix <> body)) oneBotTimeoutMs >>= \case
              Left err
                | sentAny || not (failedBeforeEffect err) -> pure (AttemptOutcomeUnknown err)
                | otherwise -> pure (AttemptRetryable err)
              -- The edge answered, so it is up: this is a refusal of the
              -- content itself (risk control, a banned link, a dead target),
              -- not a transport outage.
              Right (Response _ retcode payload _)
                | retcode /= 0 ->
                    let err = "retcode " <> T.pack (show retcode)
                     in pure $ if sentAny then AttemptOutcomeUnknown err else AttemptRejected err
                | otherwise -> do
                    let native = NativeEventId . T.pack . show <$> extractOutMid payload
                    sendChunks claim lowered (index + 1) True (firstNative <|> native) rest

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

-- | How many claimed attempts one /rejected/ delivery may spend before its
-- endpoint's ordered lane matters more than this copy.  With 'retryDelay'
-- that is 2+4+…+256 then 256s per attempt: roughly 45 minutes, long enough
-- for a transient refusal to clear and short enough that one poisoned row
-- cannot hold the conversation hostage.  An unreachable edge is not budgeted
-- at all, so this never truncates an outage backlog.
deliveryAttemptBudget :: Int
deliveryAttemptBudget = 16

deliveryBatchSize :: Int
deliveryBatchSize = 32

deliveryLeaseSeconds :: NominalDiffTime
deliveryLeaseSeconds = 120

oneBotTimeoutMs :: Int
oneBotTimeoutMs = 30000

deliveryMediaItemBytes :: Int
deliveryMediaItemBytes = 64 * 1024 * 1024

deliveryMediaTotalBytes :: Int
deliveryMediaTotalBytes = 64 * 1024 * 1024
