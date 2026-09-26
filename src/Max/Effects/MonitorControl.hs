{-# LANGUAGE TypeFamilies #-}

-- | Monitor writes carry host-bound identity, role and grants. Every mutation
-- rechecks the caller under the same transaction that changes the definition.
module Max.Effects.MonitorControl (MonitorControl, MonitorControlScope (..), MonitorArm (..), armMonitor, armHttpMonitor, controlMonitor, runMonitorControl, runMonitorControlWithAuthority) where

import Control.Monad (forM_, void)
import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Text (Text)
import Data.Time (UTCTime)
import Effectful
import Effectful.Dispatch.Dynamic (interpret, send)
import Effectful.PostgreSQL (WithConnection)
import Max.DB.Authority (authorizeCallWithin)
import Max.DB.Monitor qualified as DB
import Max.DB.Monitor.Control qualified as Control
import Max.DB.Monitor.Http qualified as HttpDB
import Max.DB.Transaction (InTransaction, withTransaction)
import Max.Execution.Authority (CallAuthority)
import Max.Jobs qualified as Jobs
import Max.Monitor.Control
import Max.Monitor.Types
  ( HttpMonitorRegistration (..),
    LedgerMatchSpec,
    MonitorOrdinal (..),
    MonitorRef,
  )
import Max.Platform.Types (PrincipalId (..))
import Max.Turn.Types (AgentTurnRef (..))
import OneBot.Types (GroupId (..))

data MonitorControlScope = MonitorControlScope
  { group :: !GroupId,
    turn :: !(Maybe AgentTurnRef),
    principal :: !PrincipalId,
    grants :: !(Map Text Text),
    armingAllowed :: !Bool,
    httpBaseUrl :: !(Maybe Text)
  }

data MonitorArm
  = TimeMonitor !Text !(Maybe Text) !UTCTime
  | LedgerMonitor !Text !LedgerMatchSpec !Int !UTCTime !Int64
  deriving stock (Eq, Show)

data MonitorControl :: Effect where
  ArmMonitor :: MonitorArm -> MonitorControl m (Either MonitorArmError MonitorRef)
  ArmHttpMonitor :: HttpMonitorSpec -> MonitorControl m (Either MonitorArmError HttpMonitorRegistration)
  ControlMonitor :: MonitorOrdinal -> MonitorCommand -> Bool -> MonitorControl m (Either MonitorControlError MonitorControlReceipt)

type instance DispatchOf MonitorControl = Dynamic

armMonitor :: (MonitorControl :> es) => MonitorArm -> Eff es (Either MonitorArmError MonitorRef)
armMonitor = send . ArmMonitor

armHttpMonitor :: (MonitorControl :> es) => HttpMonitorSpec -> Eff es (Either MonitorArmError HttpMonitorRegistration)
armHttpMonitor = send . ArmHttpMonitor

controlMonitor :: (MonitorControl :> es) => MonitorOrdinal -> MonitorCommand -> Bool -> Eff es (Either MonitorControlError MonitorControlReceipt)
controlMonitor ordinal command cancelTasks = send (ControlMonitor ordinal command cancelTasks)

runMonitorControl :: forall es a. (WithConnection :> es, IOE :> es) => Jobs.Jobs -> MonitorControlScope -> Eff (MonitorControl : es) a -> Eff es a
runMonitorControl = runMonitorControlWithAuthority Nothing

runMonitorControlWithAuthority :: forall es a. (WithConnection :> es, IOE :> es) => Maybe CallAuthority -> Jobs.Jobs -> MonitorControlScope -> Eff (MonitorControl : es) a -> Eff es a
runMonitorControlWithAuthority authority jobs scope = interpret $ \_ -> \case
  ArmHttpMonitor spec -> withCaller ArmingCallerFenced $ \turn ->
    if not scope.armingAllowed
      then pure (Left MonitorArmingForbidden)
      else case scope.httpBaseUrl of
        Nothing -> pure (Left HttpMonitorsUnavailable)
        Just base -> fmap (\registration -> registration {path = base <> registration.path}) <$> HttpDB.armHttpMonitor scope.group scope.principal turn scope.grants spec
  ArmMonitor request -> withCaller ArmingCallerFenced $ \turn ->
    case request of
      -- A time automation is its creator's own delayed request.
      TimeMonitor goal cron at -> DB.armElaboratedTimeMonitor scope.group scope.principal turn goal cron at scope.grants
      _ | not scope.armingAllowed -> pure (Left MonitorArmingForbidden)
      LedgerMonitor goal predicate cooldown expires maxFires -> DB.armLedgerMatchMonitor scope.group scope.principal turn goal predicate cooldown expires maxFires scope.grants
  ControlMonitor ordinal command cancelTasks -> do
    result <- withCaller MonitorCallerFenced $ \_ ->
      let GroupId group = scope.group; PrincipalId actor = scope.principal
       in Control.controlMonitor group actor scope.armingAllowed ordinal.unMonitorOrdinal command cancelTasks
    case result of
      Left failure -> pure (Left failure)
      Right (receipt, handles) -> do
        forM_ handles $ \identifier -> liftIO $ void (Jobs.cancelJob jobs scope.group scope.principal True identifier "monitor controller cancelled admitted work")
        pure (Right receipt)
  where
    withCaller :: forall failure result. failure -> (AgentTurnRef -> Eff (InTransaction : es) (Either failure result)) -> Eff es (Either failure result)
    withCaller failure action = case scope.turn of
      Nothing -> pure (Left failure)
      Just turn -> withTransaction $ do
        allowed <- authorizeCallWithin authority turn.atrTurnId scope.group scope.principal
        if allowed then action turn else pure (Left failure)
