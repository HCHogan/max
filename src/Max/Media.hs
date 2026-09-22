-- | Discover missing derived media from canonical history. Live ingress queues
-- directly; this cursor catches startup history and newly committed backfill.
module Max.Media (mediaDiscoveryWorker) where

import Control.Monad (forM_, when)
import Data.Time (addUTCTime, getCurrentTime)
import Effectful
import Effectful.Log
import Effectful.PostgreSQL (WithConnection)
import Max.DB.MediaMissing (missingMediaMessages)
import Max.FetchQueue (FetchPriority (MissingFetch), FetchSignal, fetchTick, waitFetch)
import Max.Files (enqueueFiles)
import Max.Forward (enqueueForwards)
import Max.Images (enqueueImages)
import Max.Platform.Store.Ingest (loadDispatchMessage)
import Max.Util (catchSync)
import Max.Worker (recovering)

mediaDiscoveryWorker :: (Log :> es, WithConnection :> es, IOE :> es) => FetchSignal -> Eff es ()
mediaDiscoveryWorker signal = do
  started <- liftIO getCurrentTime
  discover (0, addUTCTime 300 started)
  where
    discover state = recovering "media discovery" (scan state) >>= discover
    scan (cursor, rescanAt) = do
      now <- liftIO getCurrentTime
      tick <- liftIO (fetchTick signal)
      (next, messages) <- missingMediaMessages cursor
      if next == cursor
        then do
          liftIO (waitFetch signal tick)
          -- IDs can commit out of order. Revisit history after each five-minute sweep.
          pure (if now >= rescanAt then (0, addUTCTime 300 now) else (cursor, rescanAt))
        else do
          forM_ messages $ \(canonical, topLevel) ->
            ( loadDispatchMessage canonical
                >>= mapM_
                  ( \message -> do
                      enqueueImages MissingFetch signal message
                      enqueueFiles MissingFetch signal message
                      when topLevel (enqueueForwards MissingFetch signal message)
                  )
            )
              `catchSync` \err -> logAttention "media source could not be read" (object ["canonical_message_id" .= canonical, "error" .= show err])
          pure (next, rescanAt)
