-- | Event vocabulary and the single readiness predicate, independent of
-- delivery ownership, runtime state and transcript rendering.
module Max.Node.Event
  ( Body (..),
    Control (..),
    controlBody,
    Occurrence (..),
    Urgency (..),
    Pending (..),
    noPending,
    wakes,
  )
where

import Data.Aeson (Value)
import Data.Int (Int64)
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
  | -- A guest owns the selected receipt and its value; the log records only
    -- that its private await became ready, never the leaf result itself.
    GuestReady !Text
  | Fired !Occurrence
  deriving stock (Eq, Show)

data Pending = Pending {calls :: !(Set Text), children :: !(Set JobRun)}

noPending :: Pending
noPending = Pending Set.empty Set.empty

wakes :: Pending -> Body -> Bool
wakes pending = \case
  FrontendSteered {} -> True
  Steered {} -> True
  Replaced {} -> True
  Cancelled -> True
  ChildSaid _ _ Urgent -> True
  ChildDone child _ -> Set.member child pending.children
  Settled call _ _ -> Set.member call pending.calls
  GuestReady guest -> Set.member guest pending.calls
  _ -> False
