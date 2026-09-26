-- | Immutable snapshots of a node's observation log. Positions never move when
-- a task retires; projection reads only the observations owned by that task.
module Max.Node.Log
  ( Cursor,
    Observer (..),
    NodeLog,
    emptyLog,
    logCursor,
    appendObservation,
    observedBetween,
    retire,
  )
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Max.LLM.Types (ChatMessage)

newtype Cursor = Cursor Int deriving stock (Eq, Ord, Show)

newtype Observer = Observer Integer deriving stock (Eq, Ord, Show)

data NodeLog = NodeLog !Int !(Map Int (Observer, [ChatMessage])) deriving stock (Show)

emptyLog :: NodeLog
emptyLog = NodeLog 0 Map.empty

logCursor :: NodeLog -> Cursor
logCursor (NodeLog next _) = Cursor next

appendObservation :: Observer -> [ChatMessage] -> NodeLog -> NodeLog
appendObservation _ [] nodeLog = nodeLog
appendObservation owner messages (NodeLog next entries) = NodeLog (next + 1) (Map.insert next (owner, messages) entries)

observedBetween :: Observer -> Cursor -> Cursor -> NodeLog -> [ChatMessage]
observedBetween owner (Cursor start) (Cursor end) (NodeLog _ entries) =
  concat [messages | (target, messages) <- Map.elems selected, target == owner]
  where
    selected = fst (Map.split end (snd (Map.split (start - 1) entries)))

retire :: Observer -> NodeLog -> NodeLog
retire owner (NodeLog next entries) = NodeLog next (Map.filter ((/= owner) . fst) entries)
