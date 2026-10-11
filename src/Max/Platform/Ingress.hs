-- | In-memory notifications are hints. Pending projections and unstarted
-- dispatches are durable; workers also poll to recover missed wakes/restarts.
module Max.Platform.Ingress (Ingress, newIngress, queueIngest, nextIngress, projectionWorker) where

import Control.Concurrent.STM
import Control.Monad (forever, unless)
import Effectful
import Effectful.Log (Log, logAttention, object, (.=))
import Effectful.PostgreSQL (WithConnection)
import Max.DB.MessageProjection (claimMessageDispatch, processNextProjection)
import Max.Hook.Runtime (warmHookRuntime)
import Max.Platform.Delivery.Queue (DeliveryQueue, queueDeliveries)
import Max.Platform.Store.Ingest
  ( IngestResult (..),
    NewIngest (..),
  )
import Max.Platform.Types (CanonicalMessageId)
import Max.Util (catchSync)

data Ingress = Ingress (TVar Int) DeliveryQueue

newIngress :: DeliveryQueue -> IO Ingress
newIngress deliveries = do
  warmHookRuntime
  (`Ingress` deliveries) <$> newTVarIO 0

queueIngest :: Ingress -> IngestResult -> IO ()
queueIngest ingress@(Ingress _ deliveries) = \case
  Ingested event -> do
    queueDeliveries deliveries event.mirrorDeliveries
    notifyIngress ingress
  _ -> pure ()

nextIngress :: (WithConnection :> es, IOE :> es) => Ingress -> Eff es CanonicalMessageId
nextIngress ingress@(Ingress generation _) = do
  seen <- liftIO (readTVarIO generation)
  claimMessageDispatch >>= \case
    Just canonical -> pure canonical
    Nothing -> liftIO (waitIngress ingress seen) >> nextIngress ingress

projectionWorker :: (WithConnection :> es, Log :> es, IOE :> es) => Ingress -> Eff es ()
projectionWorker ingress@(Ingress generation _) = forever $ do
  seen <- liftIO (readTVarIO generation)
  processed <-
    processNextProjection `catchSync` \err -> do
      logAttention "message projection transaction failed; pending work retained" (object ["error" .= show err])
      pure False
  if processed
    then liftIO (notifyIngress ingress)
    else liftIO (waitIngress ingress seen)

notifyIngress :: Ingress -> IO ()
notifyIngress (Ingress generation _) = atomically (modifyTVar' generation (+ 1))

waitIngress :: Ingress -> Int -> IO ()
waitIngress (Ingress generation _) seen = do
  timer <- registerDelay 250000
  atomically $ do
    changed <- (/= seen) <$> readTVar generation
    expired <- readTVar timer
    unless (changed || expired) retry
