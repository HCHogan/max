-- | Process-local node events. Delivery, observation and the final-answer
-- boundary share STM state, so an accepted interrupt cannot fall between the
-- last observation and a successful task finish.
module Max.Node.Events
  ( Node,
    Task,
    Event (..),
    Body (..),
    Control (..),
    controlBody,
    Occurrence (..),
    Urgency (..),
    Pending (..),
    noPending,
    newNode,
    newTask,
    newTaskFrom,
    startTask,
    taskTrigger,
    deliver,
    deliverTracked,
    deliverAll,
    observe,
    observeAll,
    peekAll,
    observeAt,
    discard,
    wakes,
    awaitInterrupt,
    hasInterrupt,
    tryFinish,
    close,
    isOpen,
    sameNode,
    observationOwner,
    readObservations,
    appendObservation,
    Future,
    newFuture,
    settleFuture,
    pollFuture,
  )
where

import Control.Concurrent.STM
import Data.Foldable (toList)
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Sequence (Seq, (|>))
import Data.Sequence qualified as Seq
import Data.Set (Set)
import Data.Set qualified as Set
import Max.LLM.Types (ChatMessage)
import Max.Node.Event
import Max.Node.Log qualified as Log

data Event = Event {sequence :: !Integer, target :: !Integer, body :: !Body} deriving stock (Eq, Show)

newtype Node = Node (TVar State) deriving stock (Eq)

data Task = Task !Node !Integer deriving stock (Eq)

-- | A selected await owns the actual value and its event receipt. It does not
-- occupy the model's unobserved-input buffer: its value is retained by the
-- call owner and projected in the protocol result slot when the await returns.
data Future value = Future !Task !(TVar (Maybe (Event, value)))

newFuture :: Task -> STM (Future value)
newFuture task = Future task <$> newTVar Nothing

settleFuture :: Future value -> Body -> value -> STM Bool
settleFuture (Future task ref) body value = do
  existing <- readTVar ref
  active <- isOpen task
  case existing of
    Just _ -> pure False
    Nothing | not active -> pure False
    Nothing -> do
      event <- recordEvent task body
      writeTVar ref (Just (event, value))
      pure True

pollFuture :: Pending -> Future value -> STM (Maybe value)
pollFuture pending (Future task ref) = do
  active <- isOpen task
  settled <- readTVar ref
  pure $ case settled of
    Just (event, value) | active && wakes pending event.body -> Just value
    _ -> Nothing

sameNode :: Task -> Task -> Bool
sameNode (Task node _) (Task other _) = node == other

data State = State {next :: !Integer, tasks :: !(Map Integer Bool), events :: !(Seq Event), stopped :: !(Set Integer), observations :: !Log.NodeLog, triggers :: !(Map Integer Log.EventRef)}

newNode :: STM Node
newNode = Node <$> newTVar (State 0 Map.empty Seq.empty Set.empty Log.emptyLog Map.empty)

newTask :: Node -> STM Task
newTask node@(Node ref) = do
  state <- readTVar ref
  let key = state.next
  writeTVar ref state {next = key + 1, tasks = Map.insert key True state.tasks}
  pure (Task node key)

newTaskFrom :: Node -> Log.Trigger -> STM Task
newTaskFrom node trigger = do
  task <- newTask node
  _ <- startTask task trigger
  pure task

-- | Admission records exactly one immutable trigger before a model can start.
-- A staged task is useful during handoff, but cannot start a model without it.
startTask :: Task -> Log.Trigger -> STM (Maybe Log.EventRef)
startTask task@(Task (Node ref) key) trigger = do
  active <- isOpen task
  state <- readTVar ref
  if not active || Map.member key state.triggers
    then pure Nothing
    else do
      let (event, observations) = Log.appendTrigger (observationOwner task) trigger state.observations
      writeTVar ref state {observations, triggers = Map.insert key event state.triggers}
      pure (Just event)

taskTrigger :: Task -> STM (Maybe Log.EventRef)
taskTrigger (Task (Node ref) key) = Map.lookup key . (.triggers) <$> readTVar ref

observationOwner :: Task -> Log.Observer
observationOwner (Task _ key) = Log.Observer key

readObservations :: Task -> STM Log.NodeLog
readObservations (Task (Node ref) _) = (.observations) <$> readTVar ref

-- | The node owns the log. A retired or revoked task cannot resurrect a trail;
-- callers keep immutable snapshots for a poll already in progress.
appendObservation :: Task -> [ChatMessage] -> STM (Maybe Log.NodeLog)
appendObservation task@(Task (Node ref) key) messages = do
  state <- readTVar ref
  if not (Map.member key state.tasks) || Set.member key state.stopped
    then pure Nothing
    else do
      let observations = Log.appendObservation (observationOwner task) messages state.observations
      writeTVar ref state {observations}
      pure (Just observations)

isOpen :: Task -> STM Bool
isOpen (Task (Node ref) key) = Map.findWithDefault False key . (.tasks) <$> readTVar ref

-- | Refuse before accepting an effect; internal producers retain their source
-- result when the bounded buffer is full. Sequence numbers belong to the node.
deliver :: Task -> Body -> STM Bool
deliver task body = isJust <$> deliverTracked task body

-- | A delivery receipt lets the router release exactly the event observed,
-- even when multiple reports or messages share the same producer.
deliverTracked :: Task -> Body -> STM (Maybe Event)
deliverTracked task@(Task (Node ref) key) body = do
  active <- isOpen task
  state <- readTVar ref
  let terminal = case body of
        Cancelled -> True
        Replaced _ -> True
        _ -> False
      accepted =
        if terminal
          then Map.member key state.tasks && Set.notMember key state.stopped
          else active && Seq.length (Seq.filter ((== key) . (.target)) state.events) < 255
  if not accepted
    then pure Nothing
    else do
      event <- recordEvent task body
      modifyTVar' ref $ \current ->
        current
          { events = current.events |> event,
            tasks = if terminal then Map.insert key False current.tasks else current.tasks,
            stopped = if terminal then Set.insert key current.stopped else current.stopped
          }
      pure (Just event)

-- | Both an owned completion and a buffered input enter the same node log.
-- Admission and handing its receipt to the consumer share one transaction.
recordEvent :: Task -> Body -> STM Event
recordEvent task@(Task (Node ref) key) body = do
  state <- readTVar ref
  let event = Event state.next key body
  writeTVar
    ref
    state
      { next = state.next + 1,
        observations = Log.appendEvent (observationOwner task) body state.observations
      }
  pure event

-- | Multi-node control delivery either accepts every event or none. A full
-- parent log cannot leave a child steered without its parent's provenance note.
deliverAll :: [(Task, Body)] -> STM Bool
deliverAll messages =
  (mapM_ (\(task, body) -> deliver task body >>= check) messages >> pure True)
    `orElse` pure False

-- | The task record retains the rendered observations after this cut. Other
-- tasks' pending events stay in the node log and cannot be consumed here.
observe :: Task -> STM [Event]
observe = observeUpTo 200

-- | Assembly consumes one bounded event-buffer cut, retaining omitted evidence
-- before acknowledging the delivery receipts.
observeAll :: Task -> STM [Event]
observeAll = observeUpTo 256

observeUpTo :: Int -> Task -> STM [Event]
observeUpTo limit (Task (Node ref) key) = do
  state <- readTVar ref
  let selected = Seq.fromList (take limit (pendingEvents state key))
      observed = Set.fromList (map (.sequence) (toList selected))
  writeTVar ref state {events = Seq.filter (not . (`Set.member` observed) . (.sequence)) state.events}
  pure (toList selected)

peekAll :: Task -> STM [Event]
peekAll (Task (Node ref) key) = (`pendingEvents` key) <$> readTVar ref

-- | Commit only the previously frozen receipt set. Later arrivals remain
-- interrupting events for the next poll, even if the durable read saw their row.
observeAt :: Task -> Set Integer -> STM [Event]
observeAt (Task (Node ref) key) receipts = do
  state <- readTVar ref
  let selected = filter ((`Set.member` receipts) . (.sequence)) (pendingEvents state key)
  writeTVar ref state {events = Seq.filter (\event -> event.target /= key || Set.notMember event.sequence receipts) state.events}
  pure selected

pendingEvents :: State -> Integer -> [Event]
pendingEvents state key = sortOn eventOrder [event | event <- toList state.events, event.target == key]
  where
    eventOrder event = case event.body of
      FrontendSteered order _ -> (0 :: Int, toInteger order)
      _ -> (1, event.sequence)

-- | Revoke an owned delivery without consuming unrelated observations.
discard :: Task -> Integer -> STM ()
discard (Task (Node ref) key) receipt = modifyTVar' ref $ \state ->
  state {events = Seq.filter (\event -> event.target /= key || event.sequence /= receipt) state.events}

hasInterrupt :: Task -> Pending -> STM Bool
hasInterrupt (Task (Node ref) key) pending =
  any (\event -> event.target == key && wakes pending event.body) . (.events) <$> readTVar ref

awaitInterrupt :: Task -> Pending -> STM ()
awaitInterrupt task pending = hasInterrupt task pending >>= check

tryFinish :: Task -> STM Bool
tryFinish task@(Task (Node ref) key) = do
  pending <- hasInterrupt task noPending
  stopped <- Set.member key . (.stopped) <$> readTVar ref
  if pending || stopped
    then pure False
    else do
      modifyTVar' ref (\state -> state {tasks = Map.adjust (const False) key state.tasks})
      pure True

close :: Task -> STM ()
close (Task (Node ref) key) = modifyTVar' ref $ \state ->
  state {tasks = Map.delete key state.tasks, events = Seq.filter ((/= key) . (.target)) state.events, stopped = Set.delete key state.stopped, observations = Log.retire (Log.Observer key) state.observations, triggers = Map.delete key state.triggers}
