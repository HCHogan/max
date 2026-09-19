-- | Bounded current-process work. Each platform worker takes the first ready
-- endpoint head; a delayed retry blocks its destination, not the whole platform.
module Max.Platform.Delivery.Queue
  ( DeliveryQueue,
    QueuedDelivery (..),
    newDeliveryQueue,
    queueDeliveries,
    queueDeliveryRetry,
    nextDelivery,
    settleDelivery,
  )
where

import Control.Concurrent.STM
import Control.Monad (unless)
import Data.List (find)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Time
import Max.Platform.Store (DeliveryCompletion (..), DeliveryTarget (..))
import Max.Platform.Types

-- The boundary prevents provider reconciliation from resuming pre-start sends.
data DeliveryQueue = DeliveryQueue !DeliveryId !(TVar (Map.Map DeliveryId QueuedDelivery))

data QueuedDelivery = QueuedDelivery
  { target :: !DeliveryTarget,
    attempt :: !Int,
    phase :: !DeliveryPhase
  }
  deriving stock (Eq, Show)

data DeliveryPhase = Waiting !UTCTime | Sending | RetryAfterSend
  deriving stock (Eq, Show)

newDeliveryQueue :: DeliveryId -> IO DeliveryQueue
newDeliveryQueue boundary = DeliveryQueue boundary <$> newTVarIO Map.empty

queueDeliveries :: DeliveryQueue -> [DeliveryTarget] -> IO ()
queueDeliveries queue targets = do
  now <- getCurrentTime
  mapM_ (insertDelivery queue now 1 False) targets

-- | Call only after an authoritative receipt proved that this send failed.
-- If reconciliation races settlement, retain its wakeup until the worker exits.
queueDeliveryRetry :: DeliveryQueue -> DeliveryTarget -> Int -> IO ()
queueDeliveryRetry queue target attempts = do
  now <- getCurrentTime
  insertDelivery queue now (attempts + 1) True target

insertDelivery :: DeliveryQueue -> UTCTime -> Int -> Bool -> DeliveryTarget -> IO ()
insertDelivery (DeliveryQueue boundary state) now attempt isRetry target =
  unless (target.deliveryId <= boundary) $ atomically $ do
    entries <- readTVar state
    case Map.lookup target.deliveryId entries of
      Just current
        | isRetry && current.phase == Sending ->
            writeTVar state (Map.insert target.deliveryId current {phase = RetryAfterSend} entries)
      Just _ -> pure ()
      Nothing -> do
        check (Map.size entries < 1024)
        writeTVar state (Map.insert target.deliveryId (QueuedDelivery target attempt (Waiting now)) entries)

nextDelivery :: DeliveryQueue -> (Platform -> Bool) -> IO QueuedDelivery
nextDelivery (DeliveryQueue _ state) serves = loop
  where
    loop = do
      now <- getCurrentTime
      selection <- atomically $ do
        entries <- readTVar state
        let heads = endpointHeads (filter (serves . (.platform) . (.target)) (Map.elems entries))
        case find (ready now) heads of
          Just entry -> do
            writeTVar state (Map.insert entry.target.deliveryId entry {phase = Sending} entries)
            pure (Right entry)
          Nothing -> do
            let deadlines = [deadline | entry <- heads, Waiting deadline <- [entry.phase]]
            check (not (null deadlines))
            pure (Left (minimum deadlines, entries))
      case selection of
        Right entry -> pure entry
        Left (deadline, observed) -> do
          -- The STM wait may have outlived the sampled time; idle time is not
          -- a retry delay for work that just arrived.
          current <- getCurrentTime
          timer <- registerDelay (max 0 (min 60_000_000 (ceiling (diffUTCTime deadline current * 1_000_000))))
          atomically $ (readTVar timer >>= check) `orElse` (readTVar state >>= check . (/= observed))
          loop

    ready now entry = case entry.phase of
      Waiting deadline -> deadline <= now
      _ -> False

    endpointHeads = go Set.empty
      where
        go _ [] = []
        go seen (entry : rest)
          | Set.member entry.target.endpointId seen = go seen rest
          | otherwise = entry : go (Set.insert entry.target.endpointId seen) rest

settleDelivery :: DeliveryQueue -> DeliveryId -> DeliveryCompletion -> IO ()
settleDelivery (DeliveryQueue _ state) identifier completion = do
  now <- getCurrentTime
  atomically $ modifyTVar' state (Map.update (settle now) identifier)
  where
    settle now current = case completion of
      DeliveryRetry _ next -> Just (again current next)
      DeliveryAccepted _ | current.phase == RetryAfterSend -> Just (again current now)
      _ -> Nothing
    again current next = current {attempt = current.attempt + 1, phase = Waiting next}
