{-# LANGUAGE TypeFamilies #-}

-- | Submit progress and terminal reports for the bound execution. It cannot
-- select another attempt or mutate unrelated tasks.
module Max.Effects.TaskExecution (TaskExecution, reportTask, reportProgress, reportRequest, runTaskExecution) where

import Data.Text (Text)
import Effectful
import Effectful.Dispatch.Dynamic (interpret, send)
import Effectful.PostgreSQL (WithConnection)
import Max.DB.Task.Reporting qualified as DB
import Max.Task.Execution
import Max.Task.State (RequestDisposition, TaskReport)
import Max.Turn.Types (AgentTurnId)

data TaskExecution :: Effect where
  ReportTask :: TaskReport -> TaskExecution m (Either ExecutionFailure ())
  ReportProgress :: Text -> TaskExecution m (Either ExecutionFailure ())
  ReportRequest :: RequestDisposition -> Text -> TaskExecution m (Either ExecutionFailure ())

type instance DispatchOf TaskExecution = Dynamic

reportTask :: (TaskExecution :> es) => TaskReport -> Eff es (Either ExecutionFailure ())
reportTask = send . ReportTask

reportProgress :: (TaskExecution :> es) => Text -> Eff es (Either ExecutionFailure ())
reportProgress = send . ReportProgress

reportRequest :: (TaskExecution :> es) => RequestDisposition -> Text -> Eff es (Either ExecutionFailure ())
reportRequest disposition reply = send (ReportRequest disposition reply)

runTaskExecution :: forall es a. (WithConnection :> es, IOE :> es) => Maybe AgentTurnId -> Eff (TaskExecution : es) a -> Eff es a
runTaskExecution owner = interpret $ \_ -> \case
  ReportTask report -> submit (\turn -> DB.submitReport turn report)
  ReportProgress summary -> submit (\turn -> DB.submitProgress turn summary)
  ReportRequest disposition reply -> submit (\turn -> DB.submitRequest turn disposition reply)
  where
    submit :: (AgentTurnId -> Eff es Bool) -> Eff es (Either ExecutionFailure ())
    submit action = case owner of
      Nothing -> pure (Left ExecutionContextMissing)
      Just turn -> do
        accepted <- action turn
        pure (if accepted then Right () else Left ExecutionReportRejected)
