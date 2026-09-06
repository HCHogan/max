-- | Short, fenced transactions behind the adapter's narrow part journal.
module Max.Platform.Delivery.Store (planDeliveryParts, beginDeliveryPart, finishDeliveryPart, renewDelivery) where

import Control.Monad (forM_, void)
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as T
import Database.PostgreSQL.Simple (Only (..))
import Effectful
import Effectful.PostgreSQL (WithConnection, execute, query)
import Max.DB.Transaction (withTransaction)
import Max.Platform.Delivery.Parts
import Max.Platform.Store (DeliveryClaim (..), resolveNativeTarget)
import Max.Platform.Types

owned :: (WithConnection :> es, IOE :> es) => Text -> DeliveryClaim -> Eff es Bool
owned worker claim = do
  rows <- query "SELECT delivery_id FROM message_deliveries WHERE delivery_id=? AND status='sending' AND lease_owner=? AND attempt_count=? AND lease_expires_at>clock_timestamp() FOR UPDATE" (claim.deliveryId.unDeliveryId, worker, claim.attemptCount)
  pure (not (null (rows :: [Only Int64])))

renewDelivery :: (WithConnection :> es, IOE :> es) => Text -> DeliveryClaim -> Int -> Eff es Bool
renewDelivery worker claim seconds = do
  n <- execute "UPDATE message_deliveries SET lease_expires_at=max_lease_until(?) WHERE delivery_id=? AND status='sending' AND lease_owner=? AND attempt_count=? AND lease_expires_at>clock_timestamp()" (seconds, claim.deliveryId.unDeliveryId, worker, claim.attemptCount)
  pure (n == 1)

planDeliveryParts :: (WithConnection :> es, IOE :> es) => Text -> DeliveryClaim -> [Text] -> Eff es Bool
planDeliveryParts worker claim fingerprints = withTransaction $ do
  held <- owned worker claim
  if not held
    then pure False
    else do
      existing <- query "SELECT fingerprint FROM message_delivery_parts WHERE delivery_id=? ORDER BY part_index" (Only claim.deliveryId.unDeliveryId)
      if null existing
        then do
          forM_ (zip [0 :: Int ..] fingerprints) $ \(index, fingerprint) ->
            void $ execute "INSERT INTO message_delivery_parts(delivery_id,part_index,fingerprint,idempotency_key) VALUES (?,?,?,?)" (claim.deliveryId.unDeliveryId, index, fingerprint, claim.idempotencyKey <> "-" <> T.pack (show index))
          pure True
        else pure (map fromOnly existing == fingerprints)

beginDeliveryPart :: (WithConnection :> es, IOE :> es) => Text -> DeliveryClaim -> RetrySafety -> Int -> Eff es PartDecision
beginDeliveryPart worker claim safety index = withTransaction $ do
  held <- owned worker claim
  if not held
    then pure (PartRefused "delivery lease lost before part send")
    else do
      rows <- query "SELECT status,native_event_id FROM message_delivery_parts WHERE delivery_id=? AND part_index=? FOR UPDATE" (claim.deliveryId.unDeliveryId, index)
      case rows :: [(Text, Maybe Text)] of
        [("confirmed", native)] -> pure (PartRecorded (AttemptConfirmed (NativeEventId <$> native)))
        [("accepted_unconfirmed", native)] -> pure (PartRecorded (AttemptAccepted (NativeEventId <$> native)))
        [(status, _)] | status `elem` ["pending", "retry"] || (safety == IdempotentParts && status `elem` ["sending", "outcome_unknown"]) -> do
          void $ execute "UPDATE message_delivery_parts SET status='sending',attempt_count=?,updated_at=now() WHERE delivery_id=? AND part_index=?" (claim.attemptCount, claim.deliveryId.unDeliveryId, index)
          pure PartSend
        _ -> pure (PartRefused "delivery part has no safe replay")

finishDeliveryPart :: (WithConnection :> es, IOE :> es) => Text -> DeliveryClaim -> Int -> DeliveryAttempt -> Eff es Bool
finishDeliveryPart worker claim index result = withTransaction $ do
  held <- owned worker claim
  if not held
    then pure False
    else do
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
          existing <- resolveNativeTarget claim.endpointId value.unNativeEventId
          pure $ case existing of
            Just canonical | canonical /= claim.canonicalMessageId.unCanonicalMessageId -> Nothing
            _ -> Just value
      n <- execute "UPDATE message_delivery_parts SET status=?,native_event_id=?,last_error=?,updated_at=now() WHERE delivery_id=? AND part_index=? AND status='sending' AND attempt_count=?" (status :: Text, unNativeEventId <$> safeNative, err, claim.deliveryId.unDeliveryId, index, claim.attemptCount)
      pure (n == 1)
