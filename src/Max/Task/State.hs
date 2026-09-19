module Max.Task.State (TaskStatus (..), taskStatusText, parseTaskStatus, taskIsLive, TaskOperation (..), taskOperationText) where

import Data.Aeson
import Data.Text (Text)

data TaskStatus = Queued | Running | Succeeded | Failed | Cancelled | BudgetExhausted
  deriving stock (Eq, Show)

taskStatusText :: TaskStatus -> Text
taskStatusText = \case
  Queued -> "queued"
  Running -> "running"
  Succeeded -> "succeeded"
  Failed -> "failed"
  Cancelled -> "cancelled"
  BudgetExhausted -> "budget_exhausted"

parseTaskStatus :: Text -> Maybe TaskStatus
parseTaskStatus = \case
  "queued" -> Just Queued
  "running" -> Just Running
  "succeeded" -> Just Succeeded
  "failed" -> Just Failed
  "cancelled" -> Just Cancelled
  "budget_exhausted" -> Just BudgetExhausted
  _ -> Nothing

taskIsLive :: TaskStatus -> Bool
taskIsLive status = status `elem` [Queued, Running]

instance ToJSON TaskStatus where
  toJSON = String . taskStatusText

instance FromJSON TaskStatus where
  parseJSON = withText "task status" $ maybe (fail "unknown task status") pure . parseTaskStatus

data TaskOperation = Steer | Replace | Cancel deriving stock (Eq, Show)

taskOperationText :: TaskOperation -> Text
taskOperationText Steer = "steer"
taskOperationText Replace = "replace"
taskOperationText Cancel = "cancel"
