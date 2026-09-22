-- | Persist wire plans and native receipts for current-run part deduplication.
module Max.Platform.Delivery.Store (planDeliveryParts, beginDeliveryPart, finishDeliveryPart) where

import Control.Monad (forM_, void)
import Data.Text (Text)
import Data.Text qualified as T
import Database.PostgreSQL.Simple (Only (..))
import Effectful
import Effectful.PostgreSQL (WithConnection, execute, query)
import Max.DB.Transaction (withTransaction)
import Max.Platform.Delivery.Parts
import Max.Platform.Store.Delivery (DeliveryRequest (..))
import Max.Platform.Store.Relation (resolveNativeTarget)
import Max.Platform.Types

planDeliveryParts :: (WithConnection :> es, IOE :> es) => DeliveryRequest -> [Text] -> Eff es Bool
planDeliveryParts request fingerprints = withTransaction $ do
  existing <- query "SELECT fingerprint FROM message_delivery_parts WHERE delivery_id=? ORDER BY part_index" (Only request.deliveryId.unDeliveryId)
  if null existing
    then do
      forM_ (zip [0 :: Int ..] fingerprints) $ \(index, fingerprint) ->
        void $ execute "INSERT INTO message_delivery_parts(delivery_id,part_index,fingerprint,idempotency_key) VALUES (?,?,?,?)" (request.deliveryId.unDeliveryId, index, fingerprint, request.idempotencyKey <> "-" <> T.pack (show index))
      pure True
    else pure (map fromOnly existing == fingerprints)

beginDeliveryPart :: (WithConnection :> es, IOE :> es) => DeliveryRequest -> RetrySafety -> Int -> Eff es PartDecision
beginDeliveryPart request safety index = withTransaction $ do
  rows <- query "SELECT status,native_event_id FROM message_delivery_parts WHERE delivery_id=? AND part_index=? FOR UPDATE" (request.deliveryId.unDeliveryId, index)
  case rows :: [(Text, Maybe Text)] of
    [("confirmed", native)] -> pure (PartRecorded (AttemptConfirmed (NativeEventId <$> native)))
    [("accepted_unconfirmed", native)] -> pure (PartRecorded (AttemptAccepted (NativeEventId <$> native)))
    [(status, _)] | status `elem` ["pending", "retry"] || (safety == IdempotentParts && status `elem` ["sending", "outcome_unknown"]) -> do
      void $ execute "UPDATE message_delivery_parts SET status='sending',attempt_count=?,updated_at=now() WHERE delivery_id=? AND part_index=?" (request.attemptCount, request.deliveryId.unDeliveryId, index)
      pure PartSend
    _ -> pure (PartRefused "delivery part has no safe replay")

finishDeliveryPart :: (WithConnection :> es, IOE :> es) => DeliveryRequest -> Int -> DeliveryAttempt -> Eff es Bool
finishDeliveryPart request index result = withTransaction $ do
  let (status, native, err) = case result of
        AttemptConfirmed n -> ("confirmed", n, Nothing)
        AttemptAccepted n -> ("accepted_unconfirmed", n, Nothing)
        AttemptRetryable e -> ("retry", Nothing, Just e)
        AttemptRejected e -> ("retry", Nothing, Just e)
        AttemptOutcomeUnknown e -> ("outcome_unknown", Nothing, Just e)
        AttemptPermanentlyFailed e -> ("permanent_failure", Nothing, Just e)
        AttemptSuppressed e -> ("suppressed", Nothing, Just e)
        AttemptMediaFallback e -> ("permanent_failure", Nothing, Just e)
  safeNative <- case native of
    Nothing -> pure Nothing
    Just value -> do
      existing <- resolveNativeTarget request.endpointId value.unNativeEventId
      pure $ case existing of
        Just canonical | canonical /= request.canonicalMessageId.unCanonicalMessageId -> Nothing
        _ -> Just value
  n <- execute "UPDATE message_delivery_parts SET status=?,native_event_id=?,last_error=?,updated_at=now() WHERE delivery_id=? AND part_index=? AND status='sending' AND attempt_count=?" (status :: Text, unNativeEventId <$> safeNative, err, request.deliveryId.unDeliveryId, index, request.attemptCount)
  pure (n == 1)
