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
  )
where

import Control.Concurrent.STM
import Data.Aeson (Value)
import Data.Foldable (toList)
import Data.Int (Int64)
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Sequence (Seq, (|>))
import Data.Sequence qualified as Seq
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Max.Task.FrontendInput (FrontendInputView)
import Max.Task.Types (JobRun, JobSpec)
import Max.Tool.Media (InlineMedia)

data Urgency = Normal | Urgent deriving stock (Eq, Show)

-- | A monitor's admitted occurrence owns its immutable consumer and inputs.
-- External payloads cannot choose the goal, principal or grant ceiling.
data Occurrence = Occurrence {run :: !JobRun, consumer :: !JobSpec} deriving stock (Eq, Show)

-- | Terminal controls reserve one of the 256 slots, independent of data backpressure.
data Control = Cancel | Replace !Text deriving stock (Eq, Show)

controlBody :: Control -> Body
controlBody Cancel = Cancelled
controlBody (Replace objective) = Replaced objective

data Body
  = FrontendSteered !Int64 !FrontendInputView
  | Steered !Value
  | Replaced !Text
  | Cancelled
  | ChildSaid !JobRun !Text !Urgency
  | ChildDone !JobRun !Value
  | Settled !Text !Value ![InlineMedia]
  | Fired !Occurrence
  deriving stock (Eq, Show)

data Event = Event {sequence :: !Integer, target :: !Integer, body :: !Body} deriving stock (Eq, Show)

data Pending = Pending {calls :: !(Set Text), children :: !(Set JobRun)}

noPending :: Pending
noPending = Pending Set.empty Set.empty

newtype Node = Node (TVar State) deriving stock (Eq)

data Task = Task !Node !Integer deriving stock (Eq)

sameNode :: Task -> Task -> Bool
sameNode (Task node _) (Task other _) = node == other

data State = State {next :: !Integer, tasks :: !(Map Integer Bool), events :: !(Seq Event), stopped :: !(Set Integer)}

newNode :: STM Node
newNode = Node <$> newTVar (State 0 Map.empty Seq.empty Set.empty)

newTask :: Node -> STM Task
newTask node@(Node ref) = do
  state <- readTVar ref
  let key = state.next
  writeTVar ref state {next = key + 1, tasks = Map.insert key True state.tasks}
  pure (Task node key)

isOpen :: Task -> STM Bool
isOpen (Task (Node ref) key) = Map.findWithDefault False key . (.tasks) <$> readTVar ref

-- | Refuse before accepting an effect; internal producers retain their source
-- result when the bounded buffer is full. Sequence numbers belong to the node.
deliver :: Task -> Body -> STM Bool
deliver task body = maybe False (const True) <$> deliverTracked task body

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
      let event = Event state.next key body
      writeTVar
        ref
        state
          { next = state.next + 1,
            events = state.events |> event,
            tasks = if terminal then Map.insert key False state.tasks else state.tasks,
            stopped = if terminal then Set.insert key state.stopped else state.stopped
          }
      pure (Just event)

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

wakes :: Pending -> Body -> Bool
wakes pending = \case
  FrontendSteered {} -> True
  Steered {} -> True
  Replaced {} -> True
  Cancelled -> True
  ChildSaid _ _ Urgent -> True
  ChildDone child _ -> Set.member child pending.children
  Settled call _ _ -> Set.member call pending.calls
  _ -> False

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
  state {tasks = Map.delete key state.tasks, events = Seq.filter ((/= key) . (.target)) state.events, stopped = Set.delete key state.stopped}
