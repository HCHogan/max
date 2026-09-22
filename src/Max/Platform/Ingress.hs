-- | Only freshly committed live events enter the process queue. Source-native
-- deduplication stays in the store; a new process never scans old dispatch work.
module Max.Platform.Ingress (Ingress, newIngress, queueIngest, nextIngress) where

import Control.Concurrent.STM
import Control.Monad (when)
import Max.Platform.Delivery.Queue (DeliveryQueue, queueDeliveries)
import Max.Platform.Store.Ingest
  ( IngestResult (..),
    NewIngest (..),
  )
import Max.Platform.Types (CanonicalMessageId)

data Ingress = Ingress (TBQueue CanonicalMessageId) DeliveryQueue

newIngress :: DeliveryQueue -> IO Ingress
newIngress deliveries = (`Ingress` deliveries) <$> newTBQueueIO 1024

queueIngest :: Ingress -> IngestResult -> IO ()
queueIngest (Ingress queue deliveries) = \case
  Ingested event -> do
    queueDeliveries deliveries event.mirrorDeliveries
    when event.dispatchEligible (atomically (writeTBQueue queue event.canonicalMessageId))
  _ -> pure ()

nextIngress :: Ingress -> IO CanonicalMessageId
nextIngress (Ingress queue _) = atomically (readTBQueue queue)
