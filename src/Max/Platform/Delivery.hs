-- | Durable per-endpoint delivery worker and transport seam.
--
-- The worker owns leases and state transitions; adapters own protocol IO and
-- return an outcome that says whether retry is safe.  In particular a timeout
-- on QQ/iMessage is outcome-unknown and is parked for reconciliation, while a
-- Matrix transaction can safely retry with its stable idempotency key.
module Max.Platform.Delivery
  ( DeliveryAttempt (..),
    DeliveryMedia (..),
    DeliveryTransport (..),
    deliveryWorker,
    oneBotDeliveryTransport,
    attributedText,
    deliveryMediaFromContent,
    loadDeliveryMedia,
  )
where

import Control.Concurrent qualified as Concurrent
import Control.Monad (forM_)
import Data.Aeson (Result (..), Value, fromJSON, withArray, withObject, (.:), (.:?), (.!=))
import Data.Aeson.Types (Parser, parseMaybe)
import Data.ByteString.Base64 qualified as B64
import Data.ByteString.Base16 qualified as Base16
import Data.ByteString qualified as BS
import Data.Foldable (toList)
import Data.List (find)
import Data.Maybe (catMaybes)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (NominalDiffTime, addUTCTime, getCurrentTime)
import Effectful
import Effectful.Exception (SomeException)
import Effectful.Log
import Effectful.PostgreSQL (WithConnection)
import Max.Effects.Blob (Blob, blobRefFromSha256, readBlob)
import Max.Platform (PlatformBackend (..))
import Max.Platform.Store
  ( DeliveryClaim (..),
    DeliveryCompletion (..),
    claimDeliveries,
    completeDelivery,
  )
import Max.Platform.Types (NativeEventId (..), Platform, renderPlatform)
import Max.Util (trySync, trySyncIO)
import OneBot.Action (Response (..), extractOutMid, sendChatMsg)
import OneBot.Segment (Segment (..), imageSeg)
import OneBot.Types (GroupId (..), MessageId (..))

data DeliveryAttempt
  = AttemptConfirmed !(Maybe NativeEventId)
  | AttemptAccepted !(Maybe NativeEventId)
  | AttemptRetryable !Text
  | AttemptOutcomeUnknown !Text
  | AttemptPermanentlyFailed !Text
  deriving stock (Eq, Show)

-- | One bounded attachment extracted from canonical content. Blob-backed
-- media carries bytes; remote media retains its authenticated/source URL for
-- an adapter to fetch through its own bounded HTTP runtime.
data DeliveryMedia = DeliveryMedia
  { sourceUrl :: !Text,
    mimeType :: !(Maybe Text),
    declaredSize :: !(Maybe Int),
    name :: !(Maybe Text),
    bytes :: !(Maybe BS.ByteString)
  }
  deriving stock (Eq, Show)

data DeliveryTransport = DeliveryTransport
  { platform :: !Platform,
    deliver :: !(DeliveryClaim -> [DeliveryMedia] -> IO DeliveryAttempt)
  }

loadDeliveryMedia :: (Blob :> es) => Value -> Eff es [DeliveryMedia]
loadDeliveryMedia value = do
  loaded <- traverse loadOne (take deliveryMediaCountLimit (deliveryMediaFromContent value))
  let totalBytes = sum [BS.length payload | item <- loaded, Just payload <- [item.bytes]]
  if totalBytes > deliveryMediaTotalBytes
    then error "canonical delivery media exceeds total byte limit"
    else pure loaded
  where
    loadOne item
      | Just sha <- T.stripPrefix "blob:" item.sourceUrl = case blobRefFromSha256 sha of
          Nothing -> error "canonical delivery contains an invalid blob reference"
          Just ref -> do
            payload <- readBlob ref
            let actual = BS.length payload
            if actual > deliveryMediaItemBytes
              then error "canonical delivery media exceeds per-item byte limit"
              else case item.declaredSize of
                Just expected | expected /= actual -> error "canonical delivery media size changed"
                _ -> pure item {bytes = Just payload, declaredSize = Just actual}
      | Just encoded <- T.stripPrefix "base64://" item.sourceUrl =
          case B64.decode (TE.encodeUtf8 encoded) of
            Left _ -> error "canonical delivery contains invalid base64 media"
            Right payload ->
              let actual = BS.length payload
               in if actual > deliveryMediaItemBytes
                    then error "canonical delivery media exceeds per-item byte limit"
                    else case item.declaredSize of
                      Just expected | expected /= actual -> error "canonical delivery media size changed"
                      _ -> pure item {bytes = Just payload, declaredSize = Just actual}
      | otherwise = pure item

-- | Read the media projection of canonical content without performing IO.
-- Inline canonical bytes are decoded here; blob and base64-backed remote
-- sources are resolved by 'loadDeliveryMedia' under its byte limits.
deliveryMediaFromContent :: Value -> [DeliveryMedia]
deliveryMediaFromContent = maybe [] id . parseMaybe parser
  where
    parser = withArray "canonical content" (fmap catMaybes . traverse part . toList)
    part = withObject "canonical part" $ \o -> do
      partType <- o .:? "type" .!= ("" :: Text)
      if partType /= "media"
        then pure Nothing
        else do
          source <- o .: "source"
          mediaName <- o .:? "caption"
          withObject "canonical media source" (sourceParser mediaName) source
    sourceParser mediaName source = do
      kind <- source .:? "kind" .!= ("remote" :: Text)
      mediaMime <- source .:? "mime_type"
      mediaSize <- source .:? "size"
      case kind of
        "remote" -> do
          mediaUrl <- source .: "url"
          pure . Just $ DeliveryMedia mediaUrl mediaMime mediaSize mediaName Nothing
        "inline" -> do
          encoded <- source .: "bytes"
          payload <- either (fail . show) pure (Base16.decode (TE.encodeUtf8 encoded))
          pure . Just $ DeliveryMedia "inline:" mediaMime (Just (BS.length payload)) mediaName (Just payload)
        _ -> pure Nothing

deliveryWorker ::
  (Blob :> es, WithConnection :> es, Log :> es, IOE :> es) =>
  Text ->
  [DeliveryTransport] ->
  Eff es ()
deliveryWorker workerId transports = localDomain "delivery" loop
  where
    loop = do
      claims <- claimDeliveries workerId deliveryBatchSize deliveryLeaseSeconds
      if null claims
        then liftIO (Concurrent.threadDelay deliveryPollMicros)
        else forM_ claims deliverClaim
      loop

    deliverClaim claim = do
      now <- liftIO getCurrentTime
      mediaResult <- trySync (loadDeliveryMedia claim.content)
      completion <- case mediaResult of
        Left e ->
          pure (DeliveryRetry ("media load failed: " <> T.pack (show (e :: SomeException))) (addUTCTime 30 now))
        Right media -> case find ((== claim.platform) . (.platform)) transports of
          _ | Just capabilityError <- deliveryCapabilityError claim ->
            pure (DeliveryPermanentlyFailed capabilityError)
          Nothing ->
            pure (DeliveryPermanentlyFailed ("no transport registered for " <> renderPlatform claim.platform))
          Just transport ->
            liftIO (trySyncIO (transport.deliver claim media)) >>= \case
              Left e ->
                pure
                  ( DeliveryUnknown
                      ("transport exception: " <> T.pack (show (e :: SomeException)))
                      now
                  )
              Right attempt -> pure (toCompletion claim.attemptCount now attempt)
      completed <- completeDelivery workerId claim.deliveryId completion
      if completed
        then
          logInfo "delivery completed" $
            object
              [ "delivery_id" .= claim.deliveryId,
                "canonical_message_id" .= claim.canonicalMessageId,
                "platform" .= renderPlatform claim.platform,
                "outcome" .= completionName completion
              ]
        else
          logAttention "delivery lease lost before completion" $
            object ["delivery_id" .= claim.deliveryId, "worker" .= workerId]

deliveryCapabilityError :: DeliveryClaim -> Maybe Text
deliveryCapabilityError claim = case parseMaybe parser claim.capabilities of
  Nothing -> Just "endpoint capability manifest is malformed"
  Just (False, _) -> Just "endpoint does not advertise text delivery"
  Just (True, Just limit)
    | BS.length (TE.encodeUtf8 claim.renderedText) > limit ->
        Just ("text exceeds endpoint max_text_bytes=" <> T.pack (show limit))
  Just (True, _) -> Nothing
  where
    parser :: Value -> Parser (Bool, Maybe Int)
    parser = withObject "platform capabilities" $ \o ->
      (,) <$> (o .:? "send_text" .!= False) <*> o .:? "max_text_bytes"

toCompletion :: Int -> UTCTime -> DeliveryAttempt -> DeliveryCompletion
toCompletion attempts now = \case
  AttemptConfirmed native -> DeliveryConfirmedAs native
  AttemptAccepted native -> DeliveryAccepted native
  AttemptRetryable err -> DeliveryRetry err (addUTCTime (retryDelay attempts) now)
  AttemptOutcomeUnknown err -> DeliveryUnknown err now
  AttemptPermanentlyFailed err -> DeliveryPermanentlyFailed err

completionName :: DeliveryCompletion -> Text
completionName = \case
  DeliveryConfirmedAs {} -> "confirmed"
  DeliveryAccepted {} -> "accepted_unconfirmed"
  DeliveryRetry {} -> "retry"
  DeliveryUnknown {} -> "outcome_unknown"
  DeliveryPermanentlyFailed {} -> "permanent_failure"
  DeliverySuppressedAs {} -> "suppressed"

-- | Adapter for OneBot-shaped edge transports.  QQ is non-idempotent;
-- response loss after the websocket write must park the delivery.  The
-- no-client and websocket write failures are known-before-effect and retryable.
oneBotDeliveryTransport :: Platform -> Bool -> PlatformBackend -> DeliveryTransport
oneBotDeliveryTransport platform idempotent backend =
  DeliveryTransport
    { platform,
      deliver = \claim media -> case oneBotSegments claim media of
        Left err -> pure (AttemptPermanentlyFailed err)
        Right segments ->
          backend.pbCall (sendChatMsg (GroupId claim.compatibilityConversationId) segments) oneBotTimeoutMs >>= \case
            Left err
              | failedBeforeEffect err -> pure (AttemptRetryable err)
              | idempotent -> pure (AttemptRetryable err)
              | otherwise -> pure (AttemptOutcomeUnknown err)
            Right (Response _ retcode payload _)
              | retcode /= 0 -> pure (AttemptRetryable ("retcode " <> T.pack (show retcode)))
              | otherwise -> do
                  let native = NativeEventId . T.pack . show <$> extractOutMid payload
                  pure $ if idempotent then AttemptConfirmed native else AttemptAccepted native
    }

oneBotSegments :: DeliveryClaim -> [DeliveryMedia] -> Either Text [Segment]
oneBotSegments claim media
  | claim.messageOrigin == "inbound" && claim.originPlatform /= claim.platform =
      Right (replyPrefix <> [SegText (attributedText claim)] <> mapMaybeImage media)
  | otherwise = case fromJSON claim.compatibilitySegments of
      Success segments | not (null segments) -> Right segments
      Success _ -> Right (replyPrefix <> [SegText claim.renderedText])
      Error err -> Left ("invalid compatibility segments: " <> T.pack err)
  where
    replyPrefix = case claim.replyNativeEventId >>= readMessageId of
      Just message -> [SegReply message]
      Nothing -> []
    readMessageId (NativeEventId raw) = case reads (T.unpack raw) of
      [(message, "")] -> Just (MessageId message)
      _ -> Nothing

    mapMaybeImage = foldr (\item rest -> maybe rest (: rest) (asImage item)) []
    asImage item
      | maybe False ("image/" `T.isPrefixOf`) item.mimeType =
          Just . imageSeg $ case item.bytes of
            Just payload -> "base64://" <> TE.decodeUtf8 (B64.encode payload)
            Nothing -> item.sourceUrl
      | otherwise = Nothing

attributedText :: DeliveryClaim -> Text
attributedText claim =
  "["
    <> platformLabel claim.originPlatform
    <> maybe "" (" · " <>) claim.senderDisplayName
    <> "] "
    <> claim.renderedText

platformLabel :: Platform -> Text
platformLabel platform = case renderPlatform platform of
  "qq" -> "QQ"
  "matrix" -> "Matrix"
  "imessage" -> "iMessage"
  "wechatpad" -> "WeChat"
  other -> other

failedBeforeEffect :: Text -> Bool
failedBeforeEffect err =
  any (`T.isInfixOf` T.toLower err) ["no client connected", "send failed"]

retryDelay :: Int -> NominalDiffTime
retryDelay attempts = fromIntegral (min (300 :: Int) (2 ^ min 8 (max 0 attempts)))

deliveryBatchSize :: Int
deliveryBatchSize = 32

deliveryLeaseSeconds :: NominalDiffTime
deliveryLeaseSeconds = 120

deliveryPollMicros :: Int
deliveryPollMicros = 500000

oneBotTimeoutMs :: Int
oneBotTimeoutMs = 30000

deliveryMediaCountLimit :: Int
deliveryMediaCountLimit = 4

deliveryMediaItemBytes :: Int
deliveryMediaItemBytes = 64 * 1024 * 1024

deliveryMediaTotalBytes :: Int
deliveryMediaTotalBytes = 64 * 1024 * 1024
