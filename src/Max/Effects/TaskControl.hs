{-# LANGUAGE TypeFamilies #-}

-- | Task mutations bound to the current authenticated caller. The tool cannot
-- manufacture another actor or request administrator privileges. Authorization
-- is rechecked in the transaction that commits the requested transition.
module Max.Effects.TaskControl (TaskControl, TaskControlScope (..), startTask, controlTask, runTaskControl) where

import Data.Aeson (Value)
import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Text (Text)
import Effectful
import Effectful.Dispatch.Dynamic (interpret, send)
import Effectful.PostgreSQL (WithConnection)
import Max.DB.Task (admitTaskReceipt, steerChildTyped)
import Max.DB.Task.Authorization (authorizeCallerWithin)
import Max.DB.Task.Control qualified as DB
import Max.DB.Transaction (withTransaction)
import Max.Platform.Types (CanonicalMessageId, PrincipalId (..))
import Max.Task.Admission
import Max.Task.State
import Max.Task.Types (TaskProfile, taskGrants)
import Max.Turn.Types (AgentTurnRef (..))
import OneBot.Types (GroupId (..))

data TaskControlScope = TaskControlScope
  { group :: !GroupId,
    turn :: !(Maybe AgentTurnRef),
    source :: !CanonicalMessageId,
    principal :: !PrincipalId,
    grants :: !(Map Text Text),
    background :: !Bool
  }

data TaskControl :: Effect where
  StartTask :: Text -> Text -> TaskProfile -> Value -> TaskControl m (Either AdmissionError TaskAdmissionReceipt)
  ControlTask :: Int64 -> TaskOperation -> Maybe Int -> Text -> TaskControl m (Either TaskControlError TaskControlReceipt)

type instance DispatchOf TaskControl = Dynamic

startTask :: (TaskControl :> es) => Text -> Text -> TaskProfile -> Value -> Eff es (Either AdmissionError TaskAdmissionReceipt)
startTask key objective profile inputs = send (StartTask key objective profile inputs)

controlTask :: (TaskControl :> es) => Int64 -> TaskOperation -> Maybe Int -> Text -> Eff es (Either TaskControlError TaskControlReceipt)
controlTask identifier operation revision note = send (ControlTask identifier operation revision note)

runTaskControl :: (WithConnection :> es, IOE :> es) => TaskControlScope -> Eff (TaskControl : es) a -> Eff es a
runTaskControl scope = interpret $ \_ -> \case
  StartTask key objective profile inputs -> case scope.turn of
    Nothing -> pure (Left AdmissionFenced)
    Just turn -> admitTaskReceipt turn scope.source scope.principal key objective profile inputs (taskGrants profile scope.grants)
  ControlTask identifier operation revision note -> case scope.turn of
    Nothing -> pure (Left TaskCallerFenced)
    Just turn -> withTransaction $ do
      authorized <- authorizeCallerWithin turn.atrTurnId scope.group scope.principal
      if not authorized
        then pure (Left TaskCallerFenced)
        else
          if scope.background
            then if operation == Steer then steerChildTyped turn.atrTurnId identifier note else pure (Left TaskChildScopeRequired)
            else
              let GroupId group = scope.group; PrincipalId actor = scope.principal
               in DB.controlTask group actor False identifier operation revision Nothing note
