{-# LANGUAGE TypeFamilies #-}

-- | Mutations are bound to the authenticated turn; tools cannot choose an actor.
module Max.Effects.TaskControl (TaskControl, TaskControlScope (..), TaskRequest (..), StartOutcome (..), startTask, controlTask, waitTasks, runTaskControl) where

import Control.Monad (void)
import Data.Aeson (Value)
import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Time (addUTCTime, getCurrentTime)
import Effectful
import Effectful.Dispatch.Dynamic (interpret, send)
import Effectful.Exception (mask, onException)
import Effectful.PostgreSQL (WithConnection)
import Max.DB.Authority (authorizeCallerWithin)
import Max.DB.Job (admitFromTurn)
import Max.DB.Transaction (withTransaction)
import Max.Execution.Types (ExecutionStep (..), StepReservation (..))
import Max.Jobs qualified as Jobs
import Max.Platform.Types (CanonicalMessageId, PrincipalId)
import Max.Skill.Contract (Contract)
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

-- | One agent call. With @wait@, it owns the child until its report is
-- collected; cancelling the call cancels that child and its descendants.
data TaskRequest = TaskRequest
  { objective :: !Text,
    profile :: !TaskProfile,
    inputs :: !Value,
    contract :: !(Maybe Contract),
    wait :: !Bool
  }

data StartOutcome
  = StartedTask !JobView
  | FinishedTask !JobView
  deriving stock (Show)

data TaskControl :: Effect where
  StartTask :: TaskRequest -> TaskControl m (Either Text StartOutcome)
  ControlTask :: Int64 -> JobCommand -> TaskControl m (Either Text ())
  WaitTasks :: [Int64] -> TaskControl m (Either Text JobWait)

type instance DispatchOf TaskControl = Dynamic

startTask :: (TaskControl :> es) => TaskRequest -> Eff es (Either Text StartOutcome)
startTask = send . StartTask

controlTask :: (TaskControl :> es) => Int64 -> JobCommand -> Eff es (Either Text ())
controlTask identifier command = send (ControlTask identifier command)

waitTasks :: (TaskControl :> es) => [Int64] -> Eff es (Either Text JobWait)
waitTasks = send . WaitTasks

runTaskControl :: forall es a. (WithConnection :> es, IOE :> es) => Jobs.Jobs -> TaskControlScope -> Eff (TaskControl : es) a -> Eff es a
runTaskControl jobs scope = interpret $ \_ -> \case
  StartTask request -> mask $ \restore -> withCaller $ \turn -> do
    parent <- liftIO (Jobs.jobForTurn jobs turn.atrTurnId)
    now <- liftIO getCurrentTime
    let spec = JobSpec scope.group scope.principal scope.source request.objective request.profile (taskGrants request.profile scope.grants) request.inputs ((.run) <$> parent) request.contract request.wait Nothing Nothing (addUTCTime 21600 now)
    admitFromTurn jobs turn spec >>= \case
      Left failure -> pure (Left failure)
      Right started -> do
        let cancelChild = liftIO . void $ Jobs.cancelJob jobs scope.group scope.principal False started.run.jobId "owning agent call cancelled"
            awaitReport
              | isJust parent =
                  liftIO (Jobs.waitForChildren jobs turn.atrTurnId [started.run.jobId]) >>= \case
                    Right (ChildrenFinished [finished]) -> pure (Right (FinishedTask finished))
                    Right _ -> pure (Left "child result unavailable")
                    Left failure -> pure (Left failure)
              | otherwise = fmap FinishedTask <$> liftIO (Jobs.awaitJob jobs turn.atrTurnId started.run)
        if not request.wait
          then pure (Right (StartedTask started))
          else restore awaitReport `onException` cancelChild
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
