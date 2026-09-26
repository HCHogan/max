-- | Process-local delivery ownership. Results, reports and child messages stay
-- retained until observation, relay, folding or durable monitor recording.
module Max.Node.Router
  ( Router,
    Origin (..),
    Relay (..),
    ReportRelay (..),
    MessageRelay (..),
    MonitorResult (..),
    DeliveryWork (..),
    newRouter,
    deliverResult,
    deliverReport,
    deliverMessage,
    deliverMonitorResult,
    flush,
    observeResults,
    observeEvents,
    observeAllEvents,
    peekEvents,
    observeEventsAt,
    reportOwners,
    messageOwners,
    monitorOwners,
    closeTask,
    takeDelivery,
    takeRelay,
    releaseRelay,
    requeueRelay,
    releaseReport,
    requeueReport,
    releaseMessage,
    requeueMessage,
    releaseMonitorResult,
    referencedOwners,
    relayIsCurrent,
    reportIsCurrent,
    messageIsCurrent,
    monitorIsCurrent,
  )
where

import Control.Concurrent.STM
import Data.Aeson (Value, object, (.=))
import Data.Bifunctor (second)
import Data.Foldable (find)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Max.Node.Events qualified as Events
import Max.Node.Routing qualified as Routing
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
data ReportRelay = ReportRelay {identifier :: !Integer, attempt :: !Integer, job :: !JobView, target :: !(Maybe Events.Task), valid :: !(STM Bool), notes :: !(STM [Text])}

instance Eq ReportRelay where
  a == b = a.identifier == b.identifier && a.attempt == b.attempt && a.job.run == b.job.run

instance Show ReportRelay where
  show relay = "ReportRelay " <> show relay.identifier <> " " <> show relay.job.run

data MessageRelay = MessageRelay
  { identifier :: !Integer,
    attempt :: !Integer,
    job :: !JobView,
    target :: !(Maybe Events.Task),
    text :: !Text,
    urgency :: !Events.Urgency,
    valid :: !(STM Bool),
    foldIntoReport :: !(STM ()),
    answersPendingQuestion :: !(STM Bool)
  }

instance Eq MessageRelay where
  a == b = a.identifier == b.identifier && a.attempt == b.attempt && a.job.run == b.job.run

instance Show MessageRelay where
  show relay = "MessageRelay " <> show relay.identifier <> " " <> show relay.job.run

-- | Automation already published through its own turn. Its terminal delivery
-- persists business state instead of starting a second frontend turn.
data MonitorResult = MonitorResult {identifier :: !Integer, attempt :: !Integer, job :: !JobView, valid :: !(STM Bool)}

instance Eq MonitorResult where
  a == b = a.identifier == b.identifier && a.attempt == b.attempt && a.job.run == b.job.run

instance Show MonitorResult where
  show result = "MonitorResult " <> show result.identifier <> " " <> show result.job.run

data DeliveryWork = NativeResult !Relay | JobReport !ReportRelay | ChildMessage !MessageRelay | MonitorCompleted !MonitorResult deriving stock (Eq, Show)

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
    (Just (origin.target, Events.Settled reference value media))
    (\identifier -> NativeResult (Relay identifier 0 origin reference value media))
    >>= check

deliverReport :: Router -> JobView -> Maybe Events.Task -> STM Bool -> STM [Text] -> STM Bool
deliverReport router original target valid notes = do
  flush router
  messages <- notes
  let job = original {messages}
  deliver
    router
    valid
    ((,Events.ChildDone job.run (object ["child_update" .= job])) <$> target)
    (\identifier -> JobReport (ReportRelay identifier 0 job target valid notes))

deliverMonitorResult :: Router -> JobView -> STM Bool -> STM Bool
deliverMonitorResult router job valid =
  deliver router valid Nothing (\identifier -> MonitorCompleted (MonitorResult identifier 0 job valid))

-- | Normal messages belong to the parent's observation while it is open, and
-- to the final report after closure. Urgent messages become individual relays.
deliverMessage :: Router -> JobView -> Maybe Events.Task -> Text -> Events.Urgency -> STM Bool -> STM () -> STM Bool -> STM Bool
deliverMessage router job target text urgency valid foldIntoReport answers = do
  flush router
  deliver
    router
    valid
    ((,Events.ChildSaid job.run text urgency) <$> target)
    (\identifier -> ChildMessage (MessageRelay identifier 0 job target text urgency valid foldIntoReport answers))

deliveryKind :: DeliveryWork -> Routing.DeliveryKind (STM ())
deliveryKind = \case
  ChildMessage relay -> Routing.Message (relay.urgency == Events.Urgent) relay.foldIntoReport
  _ -> Routing.Completion

-- | Policy and ownership are shared by native outcomes, reports and messages.
-- A full target leaves ownership with the producer; a closed target relays.
deliver :: Router -> STM Bool -> Maybe (Events.Task, Events.Body) -> (Integer -> DeliveryWork) -> STM Bool
deliver (Router ref) valid target make = do
  allowed <- valid
  if not allowed
    then pure True
    else do
      (next, previous) <- readTVar ref
      entries <- normalizeEntries previous
      -- Normalization can fold messages. Commit its ownership transfer even
      -- when this new delivery is refused by either capacity boundary.
      writeTVar ref (next, entries)
      open <- maybe (pure False) (Events.isOpen . fst) target
      let work = make next
          decision = Routing.route (Routing.Delivery (deliveryKind work) open)
          retain delivery = case delivery of
            Nothing -> pure False
            Just state -> writeTVar ref (next + 1, Map.insert next (state, work) entries) >> pure True
      case decision of
        Routing.FoldDelivery foldIntoReport -> do
          foldIntoReport
          pure True
        _ | Map.size entries >= 1024 -> pure False
        Routing.BufferDelivery -> case target of
          Just (task, body) -> Events.deliverTracked task body >>= retain . fmap (Buffered task . (.sequence))
          Nothing -> pure False
        Routing.RelayDelivery -> retain (Just Queued)

-- | Revoke buffered deliveries before they enter a model observation. Receipt
-- identity prevents revoking an unrelated message from the same child.
observeEvents :: Router -> Events.Task -> STM [Events.Event]
observeEvents = observeWith Events.observe

observeAllEvents :: Router -> Events.Task -> STM [Events.Event]
observeAllEvents = observeWith Events.observeAll

peekEvents :: Router -> Events.Task -> STM [Events.Event]
peekEvents router task = flush router >> Events.peekAll task

observeEventsAt :: Router -> Events.Task -> Set Integer -> STM [Events.Event]
observeEventsAt router task receipts = observeWith (`Events.observeAt` receipts) router task

observeWith :: (Events.Task -> STM [Events.Event]) -> Router -> Events.Task -> STM [Events.Event]
observeWith observe router@(Router ref) task = do
  (next, entries) <- readTVar ref
  current <- normalizeEntries entries
  writeTVar ref (next, current)
  events <- observe task
  observeResults router task events
  pure events

reportOwners :: Router -> STM (Set JobRun)
reportOwners (Router ref) = do
  (_, entries) <- readTVar ref
  pure (Set.fromList [relay.job.run | (_, JobReport relay) <- Map.elems entries])

messageOwners :: Router -> STM (Set JobRun)
messageOwners (Router ref) = do
  (_, entries) <- readTVar ref
  pure (Set.fromList [relay.job.run | (_, ChildMessage relay) <- Map.elems entries])

monitorOwners :: Router -> STM (Set JobRun)
monitorOwners router@(Router ref) = do
  flush router
  (_, entries) <- readTVar ref
  pure (Set.fromList [result.job.run | (_, MonitorCompleted result) <- Map.elems entries])

observeResults :: Router -> Events.Task -> [Events.Event] -> STM ()
observeResults (Router ref) task events = modifyTVar' ref $ \(next, entries) ->
  let observed = Set.fromList (map (.sequence) events)
      keep (Buffered target eventId, _) = target /= task || Set.notMember eventId observed
      keep _ = True
   in (next, Map.filter keep entries)

closeTask :: Router -> Events.Task -> STM ()
closeTask router task = Events.close task >> flush router

flush :: Router -> STM ()
flush (Router ref) = do
  (next, entries) <- readTVar ref
  current <- normalizeEntries entries
  writeTVar ref (next, current)

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
  current <- normalizeEntries entries
  let promoted = Map.toList current
  case find (\(_, (state, work)) -> state == Queued && wanted work) promoted of
    Just (key, (_, work)) -> do
      claimed <- case work of
        NativeResult relay -> pure (NativeResult (Relay relay.identifier (relay.attempt + 1) relay.origin relay.reference relay.value relay.media))
        JobReport relay -> do
          messages <- relay.notes
          pure (JobReport (ReportRelay relay.identifier (relay.attempt + 1) relay.job {messages} relay.target relay.valid relay.notes))
        ChildMessage relay -> pure (ChildMessage (MessageRelay relay.identifier (relay.attempt + 1) relay.job relay.target relay.text relay.urgency relay.valid relay.foldIntoReport relay.answersPendingQuestion))
        MonitorCompleted result -> pure (MonitorCompleted (MonitorResult result.identifier (result.attempt + 1) result.job result.valid))
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

releaseMessage :: Router -> MessageRelay -> STM ()
releaseMessage router relay = finish router relay.identifier (ChildMessage relay) Nothing

requeueMessage :: Router -> MessageRelay -> STM ()
requeueMessage router relay = finish router relay.identifier (ChildMessage relay) (Just Queued)

releaseMonitorResult :: Router -> MonitorResult -> STM ()
releaseMonitorResult router result = finish router result.identifier (MonitorCompleted result) Nothing

-- | Only the current attempt can release or retry a claimed delivery.
finish :: Router -> Integer -> DeliveryWork -> Maybe Delivery -> STM ()
finish (Router ref) identifier work nextState =
  modifyTVar' ref . second $
    Map.update (\entry@(state, current) -> if state == InFlight && current == work then (,current) <$> nextState else Just entry) identifier

referencedOwners :: Router -> STM (Set JobRun)
referencedOwners (Router ref) = do
  (next, entries) <- readTVar ref
  live <- normalizeEntries entries
  let owners = \case NativeResult relay -> maybe [] pure relay.origin.owner; JobReport relay -> [relay.job.run]; ChildMessage relay -> [relay.job.run]; MonitorCompleted result -> [result.job.run]
  writeTVar ref (next, live)
  pure (Set.fromList (concatMap (owners . snd) (Map.elems live)))

-- Revocation removes the event and ownership atomically. Closure transfers
-- ordinary messages into the report before a report relay can be claimed.
normalizeEntries :: Map Integer (Delivery, DeliveryWork) -> STM (Map Integer (Delivery, DeliveryWork))
normalizeEntries entries = Map.fromList . concat <$> mapM normalize (Map.toList entries)
  where
    normalize (key, (state, work)) = do
      current <- isCurrent work
      if not current
        then do
          case state of Buffered task receipt -> Events.discard task receipt; _ -> pure ()
          pure []
        else do
          case state of
            Buffered task _ -> do
              open <- Events.isOpen task
              case Routing.route (Routing.Delivery (deliveryKind work) open) of
                Routing.FoldDelivery foldIntoReport -> foldIntoReport >> pure []
                Routing.RelayDelivery -> pure [(key, (Queued, work))]
                Routing.BufferDelivery -> pure [(key, (state, work))]
            _ -> pure [(key, (state, work))]

isCurrent :: DeliveryWork -> STM Bool
isCurrent = \case NativeResult relay -> relayIsCurrent relay; JobReport relay -> reportIsCurrent relay; ChildMessage relay -> messageIsCurrent relay; MonitorCompleted result -> monitorIsCurrent result

relayIsCurrent :: Relay -> STM Bool
relayIsCurrent = (.origin.valid)

reportIsCurrent :: ReportRelay -> STM Bool
reportIsCurrent = (.valid)

messageIsCurrent :: MessageRelay -> STM Bool
messageIsCurrent = (.valid)

monitorIsCurrent :: MonitorResult -> STM Bool
monitorIsCurrent = (.valid)
