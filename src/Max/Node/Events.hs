-- | Process-local node events. Delivery, observation and the final-answer
-- boundary share STM state, so an accepted interrupt cannot fall between the
-- last observation and a successful task finish.
module Max.Node.Events
  ( Node,
    Task,
    Event (..),
    Body (..),
    Urgency (..),
    Pending (..),
    noPending,
    newNode,
    newTask,
    deliver,
    deliverAll,
    observe,
    wakes,
    awaitInterrupt,
    hasInterrupt,
    tryFinish,
    close,
    isOpen,
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
import Max.Task.Types (JobRun)

data Urgency = Normal | Urgent deriving stock (Eq, Show)

data Body
  = FrontendSteered !Int64 !FrontendInputView
  | Steered !Value
  | Replaced !Text
  | Cancelled
  | ChildSaid !JobRun !Text !Urgency
  | ChildDone !JobRun !Value
  | Settled !Text !Value
  deriving stock (Eq, Show)

data Event = Event {sequence :: !Integer, target :: !Integer, body :: !Body} deriving stock (Eq, Show)

data Pending = Pending {calls :: !(Set Text), children :: !(Set JobRun)}

noPending :: Pending
noPending = Pending Set.empty Set.empty

newtype Node = Node (TVar State)

data Task = Task !Node !Integer

data State = State {next :: !Integer, tasks :: !(Map Integer Bool), events :: !(Seq Event)}

newNode :: STM Node
newNode = Node <$> newTVar (State 0 Map.empty Seq.empty)

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
deliver task@(Task (Node ref) key) body = do
  active <- isOpen task
  state <- readTVar ref
  if not active || Seq.length (Seq.filter ((== key) . (.target)) state.events) >= 256
    then pure False
    else do
      writeTVar ref state {next = state.next + 1, events = state.events |> Event state.next key body}
      pure True

-- | Multi-node control delivery either accepts every event or none. A full
-- parent log cannot leave a child steered without its parent's provenance note.
deliverAll :: [(Task, Body)] -> STM Bool
deliverAll messages =
  (mapM_ (\(task, body) -> deliver task body >>= check) messages >> pure True)
    `orElse` pure False

-- | The task record retains the rendered observations after this cut. Other
-- tasks' pending events stay in the node log and cannot be consumed here.
observe :: Task -> STM [Event]
observe (Task (Node ref) key) = do
  state <- readTVar ref
  let selected = Seq.fromList (take 200 (sortOn eventOrder [event | event <- toList state.events, event.target == key]))
      observed = Set.fromList (map (.sequence) (toList selected))
  writeTVar ref state {events = Seq.filter (not . (`Set.member` observed) . (.sequence)) state.events}
  pure (toList selected)
  where
    eventOrder event = case event.body of
      FrontendSteered order _ -> (0 :: Int, toInteger order)
      _ -> (1, event.sequence)

wakes :: Pending -> Body -> Bool
wakes pending = \case
  FrontendSteered {} -> True
  Steered {} -> True
  Replaced {} -> True
  Cancelled -> True
  ChildSaid _ _ Urgent -> True
  ChildDone child _ -> Set.member child pending.children
  Settled call _ -> Set.member call pending.calls
  _ -> False

hasInterrupt :: Task -> Pending -> STM Bool
hasInterrupt (Task (Node ref) key) pending =
  any (\event -> event.target == key && wakes pending event.body) . (.events) <$> readTVar ref

awaitInterrupt :: Task -> Pending -> STM ()
awaitInterrupt task pending = hasInterrupt task pending >>= check

tryFinish :: Task -> STM Bool
tryFinish task@(Task (Node ref) key) = do
  pending <- hasInterrupt task noPending
  if pending
    then pure False
    else do
      modifyTVar' ref (\state -> state {tasks = Map.adjust (const False) key state.tasks})
      pure True

close :: Task -> STM ()
close (Task (Node ref) key) = modifyTVar' ref $ \state ->
  state {tasks = Map.delete key state.tasks, events = Seq.filter ((/= key) . (.target)) state.events}
