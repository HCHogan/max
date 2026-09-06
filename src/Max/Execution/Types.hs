-- | Execution facts and budget steps shared by the loop and interpreters.
module Max.Execution.Types (StepReservation (..), ExecutionStep (..), JournalStart (..), JournalExecution (..), JournalFinish (..)) where

import Data.Aeson (Value)
import Data.Int (Int64)
import Data.Text (Text)
import Max.Turn.Types (AgentTurnRef, ExecutionOrdinal)

data StepReservation = CheckOnly | ReserveCall | ReserveRound deriving stock (Eq, Show)

data ExecutionStep = ExecutionCheckpoint | ExecutionWork !StepReservation deriving stock (Eq, Show)

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
  { jeJournalId :: !Int64,
    jeTurn :: !AgentTurnRef,
    jeExecutionOrdinal :: !ExecutionOrdinal,
    jeNodeId :: !Text
  }
  deriving stock (Show, Eq)

data JournalFinish
  = JournalRejected !Text !Text
  | JournalFailed !Text !Text
  | JournalSucceeded !Value
  | JournalCommitted !Value
  | JournalOutcomeUnknown !Text !Text
  deriving stock (Show, Eq)
