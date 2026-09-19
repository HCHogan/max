-- | Only freshly committed live events enter the process queue. Source-native
-- deduplication stays in the store; a new process never scans old dispatch work.
module Max.Platform.Ingress (Ingress, newIngress, queueIngest, nextIngress) where

import Control.Concurrent.STM
import Max.Platform.Store (IngestResult (..), NewIngest (..))
import Max.Platform.Types (CanonicalMessageId)

newtype Ingress = Ingress (TBQueue CanonicalMessageId)

newIngress :: IO Ingress
newIngress = Ingress <$> newTBQueueIO 1024

queueIngest :: Ingress -> IngestResult -> IO ()
queueIngest (Ingress queue) = \case
  Ingested event | event.dispatchEligible -> atomically (writeTBQueue queue event.canonicalMessageId)
  _ -> pure ()

nextIngress :: Ingress -> IO CanonicalMessageId
nextIngress (Ingress queue) = atomically (readTBQueue queue)
