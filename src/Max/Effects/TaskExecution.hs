{-# LANGUAGE TypeFamilies #-}

module Max.Effects.TaskExecution (TaskExecution, reportProgress, tellParent, askParent, runTaskExecution) where

import Data.Aeson (Value)
import Data.Text (Text)
import Effectful
import Effectful.Dispatch.Dynamic (interpret, send)
import Max.Jobs qualified as Jobs
import Max.Turn.Types (AgentTurnId)

data TaskExecution :: Effect where
  ReportProgress :: Text -> TaskExecution m (Either Text ())
  TellParent :: Text -> Bool -> TaskExecution m (Either Text ())
  AskParent :: Text -> TaskExecution m (Either Text Value)

type instance DispatchOf TaskExecution = Dynamic

reportProgress :: (TaskExecution :> es) => Text -> Eff es (Either Text ())
reportProgress = send . ReportProgress

tellParent :: (TaskExecution :> es) => Text -> Bool -> Eff es (Either Text ())
tellParent text urgent = send (TellParent text urgent)

askParent :: (TaskExecution :> es) => Text -> Eff es (Either Text Value)
askParent = send . AskParent

runTaskExecution :: (IOE :> es) => Jobs.Jobs -> Maybe AgentTurnId -> Eff (TaskExecution : es) a -> Eff es a
runTaskExecution jobs owner = interpret $ \_ -> \case
  ReportProgress summary -> do
    accepted <- maybe (pure False) (\turn -> liftIO (Jobs.reportJobProgress jobs turn summary)) owner
    pure (if accepted then Right () else Left "progress requires a current job and a nonempty, bounded summary")
  TellParent text urgent -> maybe (pure (Left "tell requires an agent")) (\turn -> liftIO (Jobs.tellParent jobs turn text urgent)) owner
  AskParent question -> maybe (pure (Left "ask requires an agent")) (\turn -> liftIO (Jobs.askParent jobs turn question)) owner
