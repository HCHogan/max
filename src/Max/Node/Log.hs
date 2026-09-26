-- | Immutable snapshots of node arrivals and observations. Positions never move
-- when a task retires; projection reads only that task's rendered observations.
module Max.Node.Log
  ( Cursor,
    Observer (..),
    EventRef,
    Trigger (..),
    triggerOwner,
    appendTrigger,
    triggerAt,
    NodeLog,
    emptyLog,
    logCursor,
    appendObservation,
    appendEvent,
    deliveredBetween,
    observedBetween,
    retire,
  )
where

import Data.Aeson (Value)
import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Max.LLM.Types (ChatMessage)
import Max.Node.Event (Body)
import Max.Platform.Types (CanonicalMessageId)
import Max.Task.Types (JobRun, JobSpec, JobView)
import Max.Tool.Media (InlineMedia)

newtype Cursor = Cursor Int deriving stock (Eq, Ord, Show)

newtype Observer = Observer Integer deriving stock (Eq, Ord, Show)

-- | Trigger references address the actual admission event in this node log.
-- The frozen initial window already renders it, so projection does not append
-- the trigger again as an observation.
data EventRef = EventRef !Observer !Int deriving stock (Eq, Show)

data Trigger
  = Said !(Maybe CanonicalMessageId)
  | Spawned !JobRun !JobSpec
  | Fired !JobRun !JobSpec
  | ChildSaid !JobView !Text
  | ChildDone !JobView
  | Settled !CanonicalMessageId !Int64 !Text !Value ![InlineMedia]
  deriving stock (Eq, Show)

data Entry = Started !Trigger | Delivered !Body | Observed ![ChatMessage] deriving stock (Show)

data NodeLog = NodeLog !Int !(Map Int (Observer, Entry)) deriving stock (Show)

triggerOwner :: EventRef -> Observer
triggerOwner (EventRef owner _) = owner

appendTrigger :: Observer -> Trigger -> NodeLog -> (EventRef, NodeLog)
appendTrigger owner trigger (NodeLog next entries) =
  (EventRef owner next, NodeLog (next + 1) (Map.insert next (owner, Started trigger) entries))

triggerAt :: EventRef -> NodeLog -> Maybe Trigger
triggerAt (EventRef owner position) (NodeLog _ entries) = case Map.lookup position entries of
  Just (target, Started trigger) | target == owner -> Just trigger
  _ -> Nothing

emptyLog :: NodeLog
emptyLog = NodeLog 0 Map.empty

logCursor :: NodeLog -> Cursor
logCursor (NodeLog next _) = Cursor next

appendObservation :: Observer -> [ChatMessage] -> NodeLog -> NodeLog
appendObservation _ [] nodeLog = nodeLog
appendObservation owner messages (NodeLog next entries) = NodeLog (next + 1) (Map.insert next (owner, Observed messages) entries)

-- | Arrival order is retained independently of model observation order.
-- Awaited outcomes are projected as protocol results in the task's poll; raw
-- deliveries never become an additional model-visible message here.
appendEvent :: Observer -> Body -> NodeLog -> NodeLog
appendEvent owner body (NodeLog next entries) = NodeLog (next + 1) (Map.insert next (owner, Delivered body) entries)

deliveredBetween :: Observer -> Cursor -> Cursor -> NodeLog -> [Body]
deliveredBetween owner (Cursor start) (Cursor end) (NodeLog _ entries) =
  [body | (target, Delivered body) <- Map.elems selected, target == owner]
  where
    selected = fst (Map.split end (snd (Map.split (start - 1) entries)))

observedBetween :: Observer -> Cursor -> Cursor -> NodeLog -> [ChatMessage]
observedBetween owner (Cursor start) (Cursor end) (NodeLog _ entries) =
  concat [messages | (target, Observed messages) <- Map.elems selected, target == owner]
  where
    selected = fst (Map.split end (snd (Map.split (start - 1) entries)))

retire :: Observer -> NodeLog -> NodeLog
retire owner (NodeLog next entries) = NodeLog next (Map.filter ((/= owner) . fst) entries)
