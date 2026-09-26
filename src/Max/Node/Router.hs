-- | Process-local delivery ownership. A result or report is retained until its
-- task observes it or a relay consumes it; final-answer closure cannot drop it.
module Max.Node.Router
  ( Router,
    Origin (..),
    Relay (..),
    ReportRelay (..),
    DeliveryWork (..),
    newRouter,
    deliverResult,
    deliverReport,
    observeResults,
    observeEvents,
    reportOwners,
    closeTask,
    takeDelivery,
    takeRelay,
    releaseRelay,
    requeueRelay,
    releaseReport,
    requeueReport,
    referencedOwners,
    relayIsCurrent,
    reportIsCurrent,
  )
where

import Control.Concurrent.STM
import Control.Monad (filterM, unless)
import Data.Aeson (Value, object, (.=))
import Data.Foldable (find)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Max.Node.Events qualified as Events
import Max.Task.Types (JobRun, JobView (..))
import Max.Tool.Media (InlineMedia)
import Max.ToolContext (ToolContext)
import Max.Turn.Types (AgentTurnId)

data Origin = Origin
  { turn :: !AgentTurnId,
    owner :: !(Maybe JobRun),
    context :: !ToolContext,
    target :: !Events.Task,
    valid :: !(STM Bool)
  }

data Relay = Relay {identifier :: !Integer, attempt :: !Integer, origin :: !Origin, reference :: !Text, value :: !Value, media :: ![InlineMedia]}

instance Eq Relay where
  a == b = a.identifier == b.identifier && a.attempt == b.attempt && a.origin.turn == b.origin.turn

instance Show Relay where
  show relay = "Relay " <> show relay.identifier <> " " <> show relay.reference

-- | The immutable report carries its original job/source/grant provenance.
-- It does not borrow the parent's lifetime or an aggregated notice slot.
data ReportRelay = ReportRelay {identifier :: !Integer, attempt :: !Integer, job :: !JobView, target :: !(Maybe Events.Task), valid :: !(STM Bool)}

instance Eq ReportRelay where
  a == b = a.identifier == b.identifier && a.attempt == b.attempt && a.job.run == b.job.run

instance Show ReportRelay where
  show relay = "ReportRelay " <> show relay.identifier <> " " <> show relay.job.run

data DeliveryWork = NativeResult !Relay | JobReport !ReportRelay deriving stock (Eq, Show)

data Delivery = Buffered !Events.Task !Integer | Queued | InFlight deriving stock (Eq)

newtype Router = Router (TVar (Integer, Map Integer (Delivery, DeliveryWork)))

newRouter :: IO Router
newRouter = Router <$> newTVarIO (0, Map.empty)

-- | Completion producers may wait for capacity. Job completion has a bounded
-- source slot in Jobs instead, and uses the same admission without blocking.
deliverResult :: Router -> Origin -> Text -> Value -> [InlineMedia] -> STM ()
deliverResult router origin reference value media =
  deliver
    router
    origin.valid
    (Just origin.target)
    (Events.Settled reference value media)
    (\identifier -> NativeResult (Relay identifier 0 origin reference value media))
    >>= check

deliverReport :: Router -> JobView -> Maybe Events.Task -> STM Bool -> STM Bool
deliverReport router job target valid =
  deliver
    router
    valid
    target
    (Events.ChildDone job.run (object ["child_update" .= job]))
    (\identifier -> JobReport (ReportRelay identifier 0 job target valid))

-- | Policy and ownership are shared by native outcomes and child reports.
-- A full target leaves ownership with the producer; a closed target relays.
deliver :: Router -> STM Bool -> Maybe Events.Task -> Events.Body -> (Integer -> DeliveryWork) -> STM Bool
deliver (Router ref) valid target body make = do
  allowed <- valid
  if not allowed
    then pure True
    else do
      (next, previous) <- readTVar ref
      entries <- sweepEntries previous
      if Map.size entries >= 1024
        then pure False
        else do
          open <- maybe (pure False) Events.isOpen target
          delivery <- case target of
            Just task | open -> fmap (Buffered task . (.sequence)) <$> Events.deliverTracked task body
            _ -> pure (Just Queued)
          case delivery of
            Nothing -> pure False
            Just state -> writeTVar ref (next + 1, Map.insert next (state, make next) entries) >> pure True

-- | Revoke buffered reports before they enter a model observation. Receipt
-- identity prevents revoking an unrelated message from the same child.
observeEvents :: Router -> Events.Task -> STM [Events.Event]
observeEvents router@(Router ref) task = do
  (next, entries) <- readTVar ref
  current <- sweepEntries entries
  writeTVar ref (next, current)
  events <- Events.observe task
  observeResults router task events
  pure events

reportOwners :: Router -> STM (Set JobRun)
reportOwners (Router ref) = do
  (_, entries) <- readTVar ref
  pure (Set.fromList [relay.job.run | (_, JobReport relay) <- Map.elems entries])

observeResults :: Router -> Events.Task -> [Events.Event] -> STM ()
observeResults (Router ref) task events = modifyTVar' ref $ \(next, entries) ->
  let observed = Set.fromList (map (.sequence) events)
      keep (Buffered target eventId, _) = target /= task || Set.notMember eventId observed
      keep _ = True
   in (next, Map.filter keep entries)

closeTask :: Router -> Events.Task -> STM ()
closeTask (Router ref) task = do
  Events.close task
  modifyTVar' ref $ \(next, entries) ->
    (next, fmap (\(delivery, work) -> (case delivery of Buffered target _ | target == task -> Queued; _ -> delivery, work)) entries)

takeDelivery :: Router -> STM DeliveryWork
takeDelivery = takeMatching (const True)

-- | Compatibility for native-only consumers; the worker uses takeDelivery so
-- reports and native completions share FIFO order and one capacity bound.
takeRelay :: Router -> STM Relay
takeRelay router =
  takeMatching (\case NativeResult _ -> True; _ -> False) router >>= \case
    NativeResult relay -> pure relay
    _ -> retry

takeMatching :: (DeliveryWork -> Bool) -> Router -> STM DeliveryWork
takeMatching wanted (Router ref) = do
  (next, entries) <- readTVar ref
  live <- Map.toList <$> sweepEntries entries
  promoted <-
    mapM
      ( \(key, (state, work)) -> do
          delivery <- case state of
            Buffered task _ -> do open <- Events.isOpen task; pure (if open then state else Queued)
            _ -> pure state
          pure (key, (delivery, work))
      )
      live
  let current = Map.fromList promoted
  case find (\(_, (state, work)) -> state == Queued && wanted work) promoted of
    Just (key, (_, work)) -> do
      let claimed = case work of
            NativeResult relay -> NativeResult (Relay relay.identifier (relay.attempt + 1) relay.origin relay.reference relay.value relay.media)
            JobReport relay -> JobReport (ReportRelay relay.identifier (relay.attempt + 1) relay.job relay.target relay.valid)
      writeTVar ref (next, Map.insert key (InFlight, claimed) current)
      pure claimed
    Nothing -> retry

releaseRelay :: Router -> Relay -> STM ()
releaseRelay router relay = finish router relay.identifier (NativeResult relay) Nothing

requeueRelay :: Router -> Relay -> STM ()
requeueRelay router relay = finish router relay.identifier (NativeResult relay) (Just Queued)

releaseReport :: Router -> ReportRelay -> STM ()
releaseReport router relay = finish router relay.identifier (JobReport relay) Nothing

requeueReport :: Router -> ReportRelay -> STM ()
requeueReport router relay = finish router relay.identifier (JobReport relay) (Just Queued)

-- | Only the current attempt can release or retry a claimed delivery.
finish :: Router -> Integer -> DeliveryWork -> Maybe Delivery -> STM ()
finish (Router ref) identifier work nextState = modifyTVar' ref $ \(next, entries) ->
  (next, Map.update (\entry@(state, current) -> if state == InFlight && current == work then (,current) <$> nextState else Just entry) identifier entries)

referencedOwners :: Router -> STM (Set JobRun)
referencedOwners (Router ref) = do
  (next, entries) <- readTVar ref
  live <- sweepEntries entries
  let owners = \case NativeResult relay -> maybe [] pure relay.origin.owner; JobReport relay -> [relay.job.run]
  writeTVar ref (next, live)
  pure (Set.fromList (concatMap (owners . snd) (Map.elems live)))

-- Dropping ownership must also remove the buffered event. Otherwise a later
-- observation could no longer tell that the producer's generation was revoked.
sweepEntries :: Map Integer (Delivery, DeliveryWork) -> STM (Map Integer (Delivery, DeliveryWork))
sweepEntries entries = Map.fromList <$> filterM keep (Map.toList entries)
  where
    keep (_, (state, work)) = do
      current <- isCurrent work
      unless current $ case state of
        Buffered task receipt -> Events.discard task receipt
        _ -> pure ()
      pure current

isCurrent :: DeliveryWork -> STM Bool
isCurrent = \case NativeResult relay -> relayIsCurrent relay; JobReport relay -> reportIsCurrent relay

relayIsCurrent :: Relay -> STM Bool
relayIsCurrent = (.origin.valid)

reportIsCurrent :: ReportRelay -> STM Bool
reportIsCurrent = (.valid)
