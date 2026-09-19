{-# LANGUAGE TypeFamilies #-}

module Max.Effects.TaskExecution (TaskExecution, reportProgress, runTaskExecution) where

import Data.Text (Text)
import Effectful
import Effectful.Dispatch.Dynamic (interpret, send)
import Max.Jobs qualified as Jobs
import Max.Turn.Types (AgentTurnId)

data TaskExecution :: Effect where
  ReportProgress :: Text -> TaskExecution m (Either Text ())

type instance DispatchOf TaskExecution = Dynamic

reportProgress :: (TaskExecution :> es) => Text -> Eff es (Either Text ())
reportProgress = send . ReportProgress

runTaskExecution :: (IOE :> es) => Jobs.Jobs -> Maybe AgentTurnId -> Eff (TaskExecution : es) a -> Eff es a
runTaskExecution jobs owner = interpret $ \_ -> \case
  ReportProgress summary -> do
    accepted <- maybe (pure False) (\turn -> liftIO (Jobs.reportJobProgress jobs turn summary)) owner
    pure (if accepted then Right () else Left "progress requires a current job and a nonempty, bounded summary")
