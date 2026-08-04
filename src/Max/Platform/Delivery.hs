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
    deliveryWorker,
    oneBotDeliveryTransport,
    loadDeliveryMedia,
    loweredText,
    oneBotNodes,
    oneBotReactionAction,
  )
where

import Control.Applicative ((<|>))
import Control.Monad (forM_)
import Data.Aeson (Result (..), fromJSON, toJSON)
import Data.ByteString qualified as BS
import Data.ByteString.Base64 qualified as B64
import Data.List (find, nubBy)
import Data.Int (Int64)
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
import Max.Effects.Blob (Blob, blobRefFromSha256, readBlob)
import Max.DB.Notify (WorkChannel (DeliveryWork), claimOrWait)
import Max.IR
import Max.IR.Lower
import Max.Platform (PlatformBackend (..))
import Max.Platform.Store
  ( DeliveryClaim (..),
    DeliveryCompletion (..),
    claimDeliveries,
    completeDelivery,
    deliveryMentionNatives,
  )
import Max.Platform.Types
  ( EventKind (..),
    NativeEventId (..),
    NativeUserId (..),
    Platform,
    PrincipalIdentityId,
    ReactionAction (..),
    renderPlatform,
  )
import Max.Util (trySync, trySyncIO)
import OneBot.Action (Action (SetMsgEmojiLike), Response (..), extractOutMid, sendChatMsg)
import OneBot.Segment (Segment (..), imageSeg, stickerSeg)
import OneBot.Types (GroupId (..), MessageId (..), UserId (..))

data DeliveryAttempt
  = AttemptConfirmed !(Maybe NativeEventId)
  | AttemptAccepted !(Maybe NativeEventId)
  | AttemptRetryable !Text
  | AttemptOutcomeUnknown !Text
  | AttemptPermanentlyFailed !Text
  | AttemptSuppressed !Text
  | -- | A native media transfer failed before a non-idempotent message send.
    -- The worker re-runs the shared lowerer with media forced to text; the
    -- adapter itself never invents a fallback.
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

-- | Resolve only media that can survive lowering's native tier and budget.
-- Blob failures and size-integrity violations are deterministic poison, not
-- transient transport failures; the worker marks them permanently failed.
loadDeliveryMedia ::
  (Blob :> es) =>
  OutboundCaps ->
  Body 'Canonical ->
  Eff es [(MediaRef, ResolvedMedia)]
loadDeliveryMedia caps body = do
  loaded <- traverse loadOne candidates
  let totalBytes = sum [BS.length bytes | (_, ResolvedBytes bytes) <- loaded]
  if totalBytes > deliveryMediaTotalBytes
    then error "canonical delivery media exceeds total byte limit"
    else pure loaded
  where
    candidates =
      nubBy (\(left, _) (right, _) -> left == right) . take (max 0 caps.maxNativeMedia) $
        mapMaybe nativeSource body.nodes

    nativeSource = \case
      NMedia (Just ref) meta
        | nativeMediaTier caps meta.kind == TierNative -> Just (ref, meta.sizeBytes)
      _ -> Nothing

    loadOne (ref, declaredSize) = case mediaRefBlobSha ref of
      Nothing -> pure (ref, ResolvedUrl (renderMediaRef ref))
      Just sha -> case blobRefFromSha256 sha of
        Nothing -> error "canonical delivery contains an invalid blob reference"
        Just blobRef -> do
          payload <- readBlob blobRef
          let actual = BS.length payload
          if actual > deliveryMediaItemBytes
            then error "canonical delivery media exceeds per-item byte limit"
            else case declaredSize of
              Just expected | expected /= fromIntegral actual ->
                error "canonical delivery media size changed"
              _ -> pure (ref, ResolvedBytes payload)

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
      now <- liftIO getCurrentTime
      (completion, lowerNotes) <- routeClaim now claim
      completed <- completeDelivery workerId claim.deliveryId lowerNotes completion
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
      let media = either (const []) id mediaResult
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
          lowered = lowerWith claim.capabilities media
      case mediaResult of
        Left e ->
          pure
            ( DeliveryPermanentlyFailed
                ("media load failed: " <> T.pack (show (e :: SomeException))),
              lowered.notes
            )
        Right _
          | null lowered.chunks -> pure (DeliverySuppressedAs "lowering produced no output", lowered.notes)
          | otherwise -> do
              firstAttempt <- runTransport transport claim (operation lowered)
              case firstAttempt of
                AttemptMediaFallback err -> do
                  let relowered = lowerWith (mediaTextCaps claim.capabilities) []
                      fallbackNote = LowerNote "media_emit" NoteFolded (Just err)
                  secondAttempt <- runTransport transport claim (operation relowered)
                  let completion' = case secondAttempt of
                        AttemptMediaFallback err' -> DeliveryPermanentlyFailed ("media fallback loop: " <> err')
                        other -> toCompletion claim.attemptCount now other
                  pure (completion', relowered.notes <> [fallbackNote])
                other -> pure (toCompletion claim.attemptCount now other, lowered.notes)

    runTransport transport claim operation =
      liftIO (trySyncIO (transport.deliver claim operation)) >>= \case
        Left e ->
          pure
            ( AttemptOutcomeUnknown
                ("transport exception: " <> T.pack (show (e :: SomeException)))
            )
        Right attempt -> pure attempt

mentionIdentities :: Body 'Canonical -> [PrincipalIdentityId]
mentionIdentities body =
  [ identity
    | NMention (MentionIdentity identity) _ <- body.nodes
  ]

toCompletion :: Int -> UTCTime -> DeliveryAttempt -> DeliveryCompletion
toCompletion attempts now = \case
  AttemptConfirmed native -> DeliveryConfirmedAs native
  AttemptAccepted native -> DeliveryAccepted native
  AttemptRetryable err -> DeliveryRetry err (addUTCTime (retryDelay attempts) now)
  AttemptOutcomeUnknown err -> DeliveryUnknown err now
  AttemptPermanentlyFailed err -> DeliveryPermanentlyFailed err
  AttemptSuppressed reason -> DeliverySuppressedAs reason
  AttemptMediaFallback err -> DeliveryPermanentlyFailed ("unhandled media fallback: " <> err)

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
        maybe (Left ("invalid OneBot mention id " <> native)) (Right . SegAt . UserId) (readInt64 native)
      NEmote emote -> case emote.raw >>= rawSegment of
        Just face@SegFace {} -> Right face
        _ -> maybe (Left ("invalid OneBot emote id " <> emote.nativeId)) (\n -> Right (SegFace n emote.name)) (readInt emote.nativeId)
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
      NMention _ display -> Right ("@" <> display)
      NMedia {} -> Right ""
      NEmote {} -> Left "text emitter received a native emote"
      NCard {} -> Left "text emitter received a native card"

-- | Adapter for OneBot-shaped edge transports.  Each lowered chunk is one
-- send.  Once any non-idempotent chunk may have taken effect, a later failure
-- parks the delivery rather than retrying and duplicating the prefix chunks.
oneBotDeliveryTransport :: Platform -> Bool -> PlatformBackend -> DeliveryTransport
oneBotDeliveryTransport platform idempotent backend =
  DeliveryTransport
    { platform,
      deliver = \claim -> \case
        DeliverMessage lowered -> sendChunks claim lowered 0 False Nothing lowered.chunks
        DeliverReaction target key action _ -> sendReaction target key action
        DeliverEdit {} -> pure (AttemptPermanentlyFailed "OneBot endpoint advertised edit without an emitter")
        DeliverRedaction {} -> pure (AttemptPermanentlyFailed "OneBot endpoint advertised redaction without an emitter")
    }
  where
    sendChunks _ _ _ _ firstNative [] =
      pure $ if idempotent then AttemptConfirmed firstNative else AttemptAccepted firstNative
    sendChunks claim lowered index sentAny firstNative (chunk : rest) =
      case oneBotNodes chunk of
        Left err -> pure (AttemptPermanentlyFailed err)
        Right body -> case replySegment index lowered.replyNative of
          Left err -> pure (AttemptPermanentlyFailed err)
          Right replyPrefix ->
            backend.pbCall (sendChatMsg (GroupId claim.compatibilityConversationId) (replyPrefix <> body)) oneBotTimeoutMs >>= \case
              Left err
                | idempotent -> pure (AttemptRetryable err)
                | sentAny || not (failedBeforeEffect err) -> pure (AttemptOutcomeUnknown err)
                | otherwise -> pure (AttemptRetryable err)
              Right (Response _ retcode payload _)
                | retcode /= 0 ->
                    let err = "retcode " <> T.pack (show retcode)
                     in pure $ if sentAny && not idempotent then AttemptOutcomeUnknown err else AttemptRetryable err
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
              | otherwise -> pure (AttemptRetryable ("retcode " <> T.pack (show retcode)))
        Nothing -> pure (AttemptSuppressed "reaction is not a QQ face id or target")

oneBotReactionAction :: NativeEventId -> Text -> ReactionAction -> Maybe Action
oneBotReactionAction (NativeEventId target) key action =
  SetMsgEmojiLike
    <$> (MessageId <$> readInt64 target)
    <*> readInt key
    <*> pure (action == ReactionAdd)

replySegment :: Int -> Maybe NativeEventId -> Either Text [Segment]
replySegment index native
  | index /= 0 = Right []
  | otherwise = case native of
      Nothing -> Right []
      Just (NativeEventId raw) ->
        maybe (Left ("invalid OneBot reply id " <> raw)) (Right . pure . SegReply . MessageId) (readInt64 raw)

readInt64 :: Text -> Maybe Int64
readInt64 raw = case reads (T.unpack raw) of
  [(value, "")] -> Just value
  _ -> Nothing

readInt :: Text -> Maybe Int
readInt raw = case reads (T.unpack raw) of
  [(value, "")] -> Just value
  _ -> Nothing

failedBeforeEffect :: Text -> Bool
failedBeforeEffect err =
  any (`T.isInfixOf` T.toLower err) ["no client connected", "send failed"]

retryDelay :: Int -> NominalDiffTime
retryDelay attempts = fromIntegral (min (300 :: Int) (2 ^ min 8 (max 0 attempts)))

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
