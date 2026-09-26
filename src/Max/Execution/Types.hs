-- | Execution facts and budget steps shared by the loop and interpreters.
module Max.Execution.Types (StepReservation (..), ExecutionStep (..), Admission (..), JournalStart (..), JournalExecution (..), JournalFinish (..)) where

import Data.Aeson (Value)
import Data.Text (Text)
import Data.Time (UTCTime)
import Max.Turn.Types (AgentTurnRef, ExecutionOrdinal)

data StepReservation = CheckOnly | ReserveCall | ReserveRound deriving stock (Eq, Show)

data ExecutionStep = ExecutionCheckpoint | ExecutionWork !StepReservation deriving stock (Eq, Show)

-- | An over-budget step is refused without stopping the agent, which still
-- writes its report; a refused step stops it.
data Admission = Admitted | OverBudget | Refused deriving stock (Eq, Show)

data JournalStart = JournalStart
  { jsCallId :: !Text,
    jsToolRef :: !Text,
    jsSchemaVersion :: !Int,
    jsSchemaHash :: !Text,
    jsInput :: !Value,
    jsEffectLabels :: !Value,
    jsRetryClass :: !Text
  }
  deriving stock (Show, Eq)

data JournalExecution = JournalExecution
  { jeTurn :: !AgentTurnRef,
    jeExecutionOrdinal :: !ExecutionOrdinal,
    jeStart :: !JournalStart,
    jeStartedAt :: !UTCTime
  }
  deriving stock (Show, Eq)

data JournalFinish
  = JournalRejected !Text !Text
  | JournalFailed !Text !Text
  | JournalSucceeded !Value
  | JournalCommitted !Value
  | JournalOutcomeUnknown !Text !Text
  deriving stock (Show, Eq)
