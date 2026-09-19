{-# LANGUAGE TypeFamilies #-}

-- | Mutations are bound to the authenticated turn; tools cannot choose an actor.
module Max.Effects.TaskControl (TaskControl, TaskControlScope (..), startTask, controlTask, waitTasks, runTaskControl) where

import Data.Aeson (Value)
import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Time (addUTCTime, getCurrentTime)
import Effectful
import Effectful.Dispatch.Dynamic (interpret, send)
import Effectful.PostgreSQL (WithConnection)
import Max.DB.Authority (authorizeCallerWithin)
import Max.DB.Job (admitFromTurn)
import Max.DB.Transaction (withTransaction)
import Max.Execution.Types (ExecutionStep (..), StepReservation (..))
import Max.Jobs qualified as Jobs
import Max.Platform.Types (CanonicalMessageId, PrincipalId)
import Max.Task.Types
import Max.Turn.Types (AgentTurnRef (..))
import OneBot.Types (GroupId)

data TaskControlScope = TaskControlScope
  { group :: !GroupId,
    turn :: !(Maybe AgentTurnRef),
    source :: !CanonicalMessageId,
    principal :: !PrincipalId,
    grants :: !(Map Text Text)
  }

data TaskControl :: Effect where
  StartTask :: Text -> TaskProfile -> Value -> TaskControl m (Either Text JobView)
  ControlTask :: Int64 -> JobCommand -> TaskControl m (Either Text ())
  WaitTasks :: [Int64] -> TaskControl m (Either Text JobWait)

type instance DispatchOf TaskControl = Dynamic

startTask :: (TaskControl :> es) => Text -> TaskProfile -> Value -> Eff es (Either Text JobView)
startTask objective profile inputs = send (StartTask objective profile inputs)

controlTask :: (TaskControl :> es) => Int64 -> JobCommand -> Eff es (Either Text ())
controlTask identifier command = send (ControlTask identifier command)

waitTasks :: (TaskControl :> es) => [Int64] -> Eff es (Either Text JobWait)
waitTasks = send . WaitTasks

runTaskControl :: forall es a. (WithConnection :> es, IOE :> es) => Jobs.Jobs -> TaskControlScope -> Eff (TaskControl : es) a -> Eff es a
runTaskControl jobs scope = interpret $ \_ -> \case
  StartTask objective profile inputs -> withCaller $ \turn -> do
    parent <- liftIO (Jobs.jobForTurn jobs turn.atrTurnId)
    now <- liftIO getCurrentTime
    let spec = JobSpec scope.group scope.principal scope.source objective profile (taskGrants profile scope.grants) inputs ((.run) <$> parent) Nothing False Nothing Nothing (addUTCTime 21600 now)
    admitFromTurn jobs turn spec
  ControlTask identifier command -> withCaller $ \turn -> do
    parent <- liftIO (Jobs.jobForTurn jobs turn.atrTurnId)
    target <- liftIO (Jobs.lookupJob jobs scope.group identifier)
    let child = case (parent, target) of
          (Just owner, Just job) -> job.spec.parent == Just owner.run
          _ -> False
    if isJust parent && (not child || case command of SteerJob _ -> False; _ -> True)
      then pure (Left "background jobs can only steer their own children")
      else liftIO $ case command of
        SteerJob note -> Jobs.steerJob jobs scope.group scope.principal (Just scope.source) identifier note
        ReplaceJob objective -> Jobs.replaceJob jobs scope.group scope.principal False identifier objective
        CancelJob reason -> Jobs.cancelJob jobs scope.group scope.principal False identifier reason
  WaitTasks children -> withCaller $ \turn -> liftIO (Jobs.waitForChildren jobs turn.atrTurnId children)
  where
    withCaller :: (AgentTurnRef -> Eff es (Either Text result)) -> Eff es (Either Text result)
    withCaller action = case scope.turn of
      Nothing -> pure (Left "task control requires an active turn")
      Just turn -> do
        live <- liftIO (Jobs.authorizeJobStep jobs turn.atrTurnId (ExecutionWork CheckOnly))
        identity <- withTransaction (authorizeCallerWithin turn.atrTurnId scope.group scope.principal)
        if live && identity then action turn else pure (Left "task caller has ended or its bound identity is invalid")
