-- | Node routing policy from a frozen view. Frontend admission, delivery
-- ownership and durable occurrence stores apply these decisions inside the
-- same transaction that supplied the view. Authority remains with the caller.
module Max.Node.Routing
  ( Input (..),
    FrontendInput (..),
    FrontendOwner (..),
    DeliveryKind (..),
    DeliveryRoute (..),
    route,
    OccurrenceBuffer (..),
    MergeCandidate (..),
    OccurrenceRoute (..),
    OverflowReason (..),
    overflowReason,
  )
where

import Data.Int (Int64)
import Data.List (find, sortOn)
import Data.Ord (Down (..))
import Data.Text (Text)
import Max.Monitor.Policy (OverlapPolicy (..))
import Max.Monitor.Types (MonitorFireId)
import Max.Platform.Types (PrincipalId)
import Max.Task.FrontendInput (FrontendInputView (..))

-- The result type keeps each adapter's actions exhaustive without admitting
-- impossible combinations such as merging a frontend reply into a monitor.
data Input result where
  Frontend :: (Eq owner) => FrontendInput owner -> [FrontendOwner owner] -> Input (Maybe owner)
  Delivery :: DeliveryKind folded -> Bool -> Input (DeliveryRoute folded)
  Occurrence :: OverlapPolicy -> Int -> Int64 -> OccurrenceBuffer -> Input OccurrenceRoute

data FrontendInput owner = FrontendInput
  { sender :: !PrincipalId,
    ingestOrder :: !(Maybe Int64),
    replyOwner :: !(Maybe owner),
    feedback :: !(Maybe FrontendInputView)
  }

data FrontendOwner owner = FrontendOwner
  { recipient :: !owner,
    order :: !Int64,
    principal :: !PrincipalId,
    sourceOrder :: !(Maybe Int64),
    sourceMessage :: !(Maybe Int64),
    open :: !Bool,
    started :: !Bool
  }

data DeliveryKind folded = Completion | Message !Bool !folded

data DeliveryRoute folded = BufferDelivery | RelayDelivery | FoldDelivery !folded deriving stock (Eq, Show)

data OccurrenceBuffer = OccurrenceBuffer {queued :: !Int, oldest :: !(Maybe MergeCandidate)} deriving stock (Eq, Show)

data MergeCandidate = MergeCandidate {fire :: !MonitorFireId, mutable :: !Bool, messages :: !Int, bytes :: !Int64} deriving stock (Eq, Show)

data OverflowReason = QueueFull | ConsumerFrozen | AggregateFull deriving stock (Eq, Show)

data OccurrenceRoute = BufferOccurrence | MergeInto !MonitorFireId | RecordOverflow !OverflowReason deriving stock (Eq, Show)

route :: Input result -> result
route (Frontend input owners) = (.recipient) <$> find accepts (sortOn (Down . (.order)) owners)
  where
    accepts owner =
      owner.open && newer owner && case input.feedback of
        Nothing -> False
        Just note -> case note.replyTo of
          -- Quoted input can reach a queued owner before its first segment.
          Just message -> case input.replyOwner of
            Just target -> owner.recipient == target
            Nothing -> owner.sourceMessage == Just message
          Nothing -> owner.started && note.kind == "steering" && input.sender == owner.principal
    newer owner = case (owner.sourceOrder, input.ingestOrder) of
      (Just previous, Just incoming) -> incoming > previous
      _ -> False
route (Delivery _ True) = BufferDelivery
route (Delivery (Message False foldIntoReport) False) = FoldDelivery foldIntoReport
route (Delivery _ False) = RelayDelivery
-- A coalesced consumer freezes its inputs at admission. Retryable ingress
-- can decline overflow without consuming the occurrence's deduplication key.
route (Occurrence QueueOccurrences capacity _ buffer)
  | buffer.queued >= capacity = RecordOverflow QueueFull
  | otherwise = BufferOccurrence
route (Occurrence Coalesce _ incomingBytes buffer) = case buffer.oldest of
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
