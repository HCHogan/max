-- | Task admission results, separate from database records and tool JSON.
module Max.Task.Admission (AdmissionError (..), admissionErrorText, TaskAdmissionReceipt (..)) where

import Data.Aeson (ToJSON (..), object, (.=))
import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Time (UTCTime)
import Max.Task.State (TaskStatus)
import Max.Task.Types (TaskProfile, profileName)

data AdmissionError
  = AdmissionFenced
  | InvalidAdmission
  | AdmissionSourceOutsideScope
  | AdmissionWidenedAuthority
  | AdmissionDepthLimit
  | AdmissionQueueFull
  deriving stock (Eq, Show)

admissionErrorText :: AdmissionError -> Text
admissionErrorText = \case
  AdmissionFenced -> "source execution was fenced"
  InvalidAdmission -> "invalid task admission"
  AdmissionSourceOutsideScope -> "source message outside conversation"
  AdmissionWidenedAuthority -> "child authority exceeds parent or profile"
  AdmissionDepthLimit -> "task depth limit"
  AdmissionQueueFull -> "conversation task queue is full"

data TaskAdmissionReceipt = TaskAdmissionReceipt
  { taskId :: !Int64,
    revision :: !Int,
    status :: !TaskStatus,
    profile :: !TaskProfile,
    deadline :: !UTCTime,
    maxCalls :: !Int,
    maxRounds :: !Int,
    grants :: !(Map Text Text)
  }
  deriving stock (Eq, Show)

instance ToJSON TaskAdmissionReceipt where
  toJSON task =
    object
      [ "task_id" .= task.taskId,
        "revision" .= task.revision,
        "status" .= task.status,
        "profile" .= profileName task.profile,
        "deadline" .= task.deadline,
        "max_calls" .= task.maxCalls,
        "max_rounds" .= task.maxRounds,
        "effective_tools" .= Map.keys task.grants
      ]
