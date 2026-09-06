-- | Ordered wire parts, with explicit transport idempotency and durable receipts.
-- All preparation precedes the first external effect. A successful part is
-- never sent again; an uncertain part can only be replayed by an idempotent edge.
module Max.Platform.Delivery.Parts
  ( DeliveryAttempt (..),
    PartDecision (..),
    PartJournal (..),
    RetrySafety (..),
    runDeliveryParts,
    wireFingerprint,
    prepareParts,
  )
where

import Control.Applicative ((<|>))
import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString.Base16 qualified as Base16
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Max.IR
import Max.Platform.Types (NativeEventId)
import Max.Util (trySyncIO)

data DeliveryAttempt
  = AttemptConfirmed !(Maybe NativeEventId)
  | AttemptAccepted !(Maybe NativeEventId)
  | AttemptRetryable !Text
  | AttemptRejected !Text
  | AttemptOutcomeUnknown !Text
  | AttemptPermanentlyFailed !Text
  | AttemptSuppressed !Text
  | AttemptMediaFallback !Text
  deriving stock (Eq, Show)

data RetrySafety = IdempotentParts | NonIdempotentParts deriving stock (Eq, Show)

data PartDecision = PartSend | PartRecorded !DeliveryAttempt | PartRefused !Text deriving stock (Eq, Show)

data PartJournal = PartJournal
  { plan :: !([Text] -> IO Bool),
    begin :: !(RetrySafety -> Int -> IO PartDecision),
    finish :: !(Int -> DeliveryAttempt -> IO Bool)
  }

-- | Preserve an ordered preparation failure without emitting a partial prefix.
prepareParts :: (Int -> a -> IO (Either e b)) -> [a] -> IO (Either e [b])
prepareParts prepare = go 0
  where
    go _ [] = pure (Right [])
    go i (x : xs) =
      prepare i x >>= \case
        Left e -> pure (Left e)
        Right value -> fmap (value :) <$> go (i + 1) xs

runDeliveryParts ::
  PartJournal ->
  RetrySafety ->
  (Maybe NativeEventId -> DeliveryAttempt) ->
  [Text] ->
  [a] ->
  (Int -> a -> IO DeliveryAttempt) ->
  IO DeliveryAttempt
runDeliveryParts journal safety complete fingerprints payloads send = do
  planned <- journal.plan fingerprints
  if length fingerprints /= length payloads || not planned
    then pure (AttemptOutcomeUnknown "delivery ownership lost or wire plan changed")
    else go 0 Nothing payloads
  where
    go _ native [] = pure (complete native)
    go index native (payload : rest) =
      journal.begin safety index >>= \case
        PartRefused err -> pure (AttemptOutcomeUnknown err)
        PartRecorded result -> continue index native rest result
        PartSend -> do
          result <-
            trySyncIO (send index payload) >>= \case
              Left err -> pure (AttemptOutcomeUnknown (T.pack (show err)))
              Right value -> pure value
          -- An idempotent transaction can safely recover an uncertain response.
          let settled = case (safety, result) of
                (IdempotentParts, AttemptOutcomeUnknown err) -> AttemptRetryable err
                _ -> result
          recorded <- journal.finish index settled
          if recorded
            then continue index native rest settled
            else pure (AttemptOutcomeUnknown "delivery ownership lost before part receipt was recorded")
    continue index native rest = \case
      AttemptConfirmed value -> go (index + 1) (native <|> value) rest
      AttemptAccepted value -> go (index + 1) (native <|> value) rest
      other -> pure other

-- | Pin semantic wire input before uploads create fresh temporary URLs. Hash
-- media bytes separately so rendering a fingerprint never expands attachments.
wireFingerprint :: Maybe NativeEventId -> [Node 'Lowered] -> Text
wireFingerprint reply nodes = hashText (T.pack (show (reply, map compact nodes)))
  where
    hashText = TE.decodeUtf8 . Base16.encode . SHA256.hash . TE.encodeUtf8
    compact (NMedia (ResolvedBytes bytes) meta) =
      NMedia (ResolvedUrl ("sha256:" <> TE.decodeUtf8 (Base16.encode (SHA256.hash bytes)))) meta
    compact node = node
