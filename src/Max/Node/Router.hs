-- | Process-local delivery ownership. A result is retained until its task
-- observes it or a relay task consumes it; final-answer closure cannot drop it.
module Max.Node.Router
  ( Router,
    Origin (..),
    Relay (..),
    newRouter,
    deliverResult,
    observeResults,
    closeTask,
    takeRelay,
    releaseRelay,
    requeueRelay,
    referencedOwners,
    relayIsCurrent,
  )
where

import Control.Concurrent.STM
import Control.Monad (filterM)
import Data.Aeson (Value)
import Data.Foldable (find)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Max.Node.Events qualified as Events
import Max.Task.Types (JobRun)
import Max.ToolContext (ToolContext)
import Max.Turn.Types (AgentTurnId)

data Origin = Origin
  { turn :: !AgentTurnId,
    owner :: !(Maybe JobRun),
    context :: !ToolContext,
    target :: !Events.Task,
    valid :: !(STM Bool)
  }

data Relay = Relay {identifier :: !Integer, attempt :: !Integer, origin :: !Origin, reference :: !Text, value :: !Value}

instance Eq Relay where
  a == b = a.identifier == b.identifier && a.attempt == b.attempt && a.origin.turn == b.origin.turn

instance Show Relay where
  show relay = "Relay " <> show relay.identifier <> " " <> show relay.reference

data Delivery = Buffered | Queued | InFlight deriving stock (Eq)

newtype Router = Router (TVar (Integer, Map Integer (Delivery, Relay)))

newRouter :: IO Router
newRouter = Router <$> newTVarIO (0, Map.empty)

-- | Full buffers apply backpressure to the completion producer. Closure and
-- revocation are read in the same transaction, so neither can strand a producer.
deliverResult :: Router -> Origin -> Text -> Value -> STM ()
deliverResult (Router ref) origin reference value = do
  allowed <- origin.valid
  if not allowed
    then pure ()
    else do
      (next, previous) <- readTVar ref
      entries <- Map.fromList <$> filterM (relayIsCurrent . snd . snd) (Map.toList previous)
      check (Map.size entries < 1024)
      open <- Events.isOpen origin.target
      delivery <-
        if open
          then do
            accepted <- Events.deliver origin.target (Events.Settled reference value)
            check accepted
            pure Buffered
          else pure Queued
      let relay = Relay next 0 origin reference value
      writeTVar ref (next + 1, Map.insert next (delivery, relay) entries)

observeResults :: Router -> Events.Task -> [Events.Event] -> STM ()
observeResults (Router ref) task events = modifyTVar' ref $ \(next, entries) ->
  let observed = Set.fromList [reference | Events.Event {body = Events.Settled reference _} <- events]
      keep (delivery, relay) = delivery /= Buffered || relay.origin.target /= task || Set.notMember relay.reference observed
   in (next, Map.filter keep entries)

closeTask :: Router -> Events.Task -> STM ()
closeTask (Router ref) task = do
  Events.close task
  modifyTVar' ref $ \(next, entries) ->
    (next, fmap (\(delivery, relay) -> (if delivery == Buffered && relay.origin.target == task then Queued else delivery, relay)) entries)

takeRelay :: Router -> STM Relay
takeRelay (Router ref) = do
  (next, entries) <- readTVar ref
  valid <- filterM (relayIsCurrent . snd . snd) (Map.toList entries)
  let current = Map.fromList valid
  case find ((== Queued) . fst . snd) valid of
    Just (key, (_, relay)) -> do
      let claimed = relay {attempt = relay.attempt + 1}
      writeTVar ref (next, Map.insert key (InFlight, claimed) current)
      pure claimed
    Nothing -> do
      -- An empty take retries; stale entries are also swept on delivery.
      retry

-- | An earlier dispatch can finish cleanup after a requeued result has been
-- claimed again. Only the current attempt owns release and retry transitions.
releaseRelay :: Router -> Relay -> STM ()
releaseRelay (Router ref) relay = modifyTVar' ref (\(next, entries) -> (next, Map.update (\entry@(delivery, current) -> if delivery == InFlight && current == relay then Nothing else Just entry) relay.identifier entries))

requeueRelay :: Router -> Relay -> STM ()
requeueRelay (Router ref) relay = modifyTVar' ref (\(next, entries) -> (next, Map.adjust (\entry@(delivery, current) -> if delivery == InFlight && current == relay then (Queued, current) else entry) relay.identifier entries))

referencedOwners :: Router -> STM (Set JobRun)
referencedOwners (Router ref) = do
  (_, entries) <- readTVar ref
  live <- filterM (relayIsCurrent . snd) (Map.elems entries)
  modifyTVar' ref (\(next, _) -> (next, Map.fromList [(relay.identifier, (delivery, relay)) | (delivery, relay) <- live]))
  pure (Set.fromList [owner | (_, relay) <- live, Just owner <- [relay.origin.owner]])

relayIsCurrent :: Relay -> STM Bool
relayIsCurrent = (.origin.valid)
