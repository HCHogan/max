{-# LANGUAGE TypeFamilies #-}

-- | Monitor writes carry host-bound identity, role and grants. Every mutation
-- rechecks the caller under the same transaction that changes the definition.
module Max.Effects.MonitorControl (MonitorControl, MonitorControlScope (..), MonitorArm (..), armMonitor, controlMonitor, runMonitorControl) where

import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Text (Text)
import Data.Time (UTCTime)
import Effectful
import Effectful.Dispatch.Dynamic (interpret, send)
import Effectful.PostgreSQL (WithConnection)
import Max.DB.Monitor qualified as DB
import Max.DB.Task.Authorization (authorizeCallerWithin)
import Max.DB.Task.MonitorControl qualified as Control
import Max.DB.Transaction (withTransaction)
import Max.Monitor.Control
import Max.Monitor.Types (LedgerMatchSpec, MonitorOrdinal (..), MonitorRef)
import Max.Platform.Types (PrincipalId (..))
import Max.Turn.Types (AgentTurnRef (..))
import OneBot.Types (GroupId (..))

data MonitorControlScope = MonitorControlScope
  { group :: !GroupId,
    turn :: !(Maybe AgentTurnRef),
    principal :: !PrincipalId,
    grants :: !(Map Text Text),
    armingAllowed :: !Bool
  }

data MonitorArm
  = CannedReminder !Text !(Maybe Text) !UTCTime
  | TimeMonitor !Text !(Maybe Text) !UTCTime
  | LedgerMonitor !Text !LedgerMatchSpec !Int !UTCTime !Int64
  deriving stock (Eq, Show)

data MonitorControl :: Effect where
  ArmMonitor :: MonitorArm -> MonitorControl m (Either MonitorArmError MonitorRef)
  ControlMonitor :: MonitorOrdinal -> MonitorCommand -> Bool -> MonitorControl m (Either MonitorControlError MonitorControlReceipt)

type instance DispatchOf MonitorControl = Dynamic

armMonitor :: (MonitorControl :> es) => MonitorArm -> Eff es (Either MonitorArmError MonitorRef)
armMonitor = send . ArmMonitor

controlMonitor :: (MonitorControl :> es) => MonitorOrdinal -> MonitorCommand -> Bool -> Eff es (Either MonitorControlError MonitorControlReceipt)
controlMonitor ordinal command cancelTasks = send (ControlMonitor ordinal command cancelTasks)

runMonitorControl :: forall es a. (WithConnection :> es, IOE :> es) => MonitorControlScope -> Eff (MonitorControl : es) a -> Eff es a
runMonitorControl scope = interpret $ \_ -> \case
  ArmMonitor request -> withCaller ArmingCallerFenced $ \turn ->
    case request of
      CannedReminder body cron at -> Right <$> DB.armCannedTimeMonitor scope.group scope.principal (Just turn) body cron at
      _ | not scope.armingAllowed -> pure (Left MonitorArmingForbidden)
      TimeMonitor goal cron at -> DB.armElaboratedTimeMonitor scope.group scope.principal turn goal cron at scope.grants
      LedgerMonitor goal predicate cooldown expires maxFires -> DB.armLedgerMatchMonitor scope.group scope.principal turn goal predicate cooldown expires maxFires scope.grants
  ControlMonitor ordinal command cancelTasks -> withCaller MonitorCallerFenced $ \_ ->
    let GroupId group = scope.group; PrincipalId actor = scope.principal
     in Control.controlMonitor group actor scope.armingAllowed ordinal.unMonitorOrdinal command cancelTasks
  where
    withCaller :: forall failure result. failure -> (AgentTurnRef -> Eff es (Either failure result)) -> Eff es (Either failure result)
    withCaller failure action = case scope.turn of
      Nothing -> pure (Left failure)
      Just turn -> withTransaction $ do
        allowed <- authorizeCallerWithin turn.atrTurnId scope.group scope.principal
        if allowed then action turn else pure (Left failure)
