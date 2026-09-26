-- | Root routing decisions from frozen facts. Stores provide a locked view of
-- their durable buffer and apply the decision in that same transaction.
module Max.Node.Routing
  ( OccurrenceBuffer (..),
    MergeCandidate (..),
    OccurrenceRoute (..),
    OverflowReason (..),
    routeOccurrence,
    overflowReason,
  )
where

import Data.Int (Int64)
import Data.Text (Text)
import Max.Monitor.Policy (OverlapPolicy (..))
import Max.Monitor.Types (MonitorFireId)

data OccurrenceBuffer = OccurrenceBuffer {queued :: !Int, oldest :: !(Maybe MergeCandidate)} deriving stock (Eq, Show)

data MergeCandidate = MergeCandidate {fire :: !MonitorFireId, mutable :: !Bool, messages :: !Int, bytes :: !Int64} deriving stock (Eq, Show)

data OverflowReason = QueueFull | ConsumerFrozen | AggregateFull deriving stock (Eq, Show)

data OccurrenceRoute = BufferOccurrence | MergeInto !MonitorFireId | RecordOverflow !OverflowReason deriving stock (Eq, Show)

-- | A coalesced stream has one pending consumer. Once admitted, its inputs are
-- immutable; later evidence cannot be appended behind that consumer's back.
-- Retryable ingress may decline RecordOverflow without consuming its key.
routeOccurrence :: OverlapPolicy -> Int -> Int64 -> OccurrenceBuffer -> OccurrenceRoute
routeOccurrence QueueOccurrences capacity _ buffer
  | buffer.queued >= capacity = RecordOverflow QueueFull
  | otherwise = BufferOccurrence
routeOccurrence Coalesce _ incomingBytes buffer = case buffer.oldest of
  Nothing | buffer.queued == 0 -> BufferOccurrence
  Just candidate
    | not candidate.mutable -> RecordOverflow ConsumerFrozen
    | candidate.messages >= 64 || candidate.bytes + incomingBytes > 131072 -> RecordOverflow AggregateFull
    | otherwise -> MergeInto candidate.fire
  _ -> RecordOverflow ConsumerFrozen

overflowReason :: OverflowReason -> Text
overflowReason = \case
  QueueFull -> "bounded monitor queue full"
  ConsumerFrozen -> "pending monitor consumer already owns frozen inputs"
  AggregateFull -> "bounded monitor aggregate full"
