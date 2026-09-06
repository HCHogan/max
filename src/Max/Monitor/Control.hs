-- | Monitor commands, policies and failure vocabulary. No storage authority.
module Max.Monitor.Control
  ( MonitorCommand (..),
    MonitorControlError (..),
    MonitorControlReceipt (..),
    MonitorArmError (..),
    PendingPolicy (..),
    parsePendingPolicy,
    monitorControlErrorText,
    armErrorText,
  )
where

import Data.Aeson (ToJSON (..), object, (.=))
import Data.Text (Text)
import Max.Monitor.Policy (OverlapPolicy)
import Max.Task.Types (TaskProfile)

data MonitorArmError
  = ArmedMonitorCapReached
  | ConditionMonitorCapReached
  | ArmingTurnOutsideConversation
  | MonitorArmingForbidden
  | ArmingCallerFenced
  deriving stock (Show, Eq)

data MonitorCommand
  = CancelMonitor
  | ConfigureMonitor !Int !Text !OverlapPolicy !Int !PendingPolicy !(Maybe (TaskProfile, Bool))
  deriving stock (Eq, Show)

data MonitorControlError = MonitorNotFound | MonitorOwnerRequired | MonitorRevisionConflict | InvalidMonitorDefinition | MonitorCallerFenced
  deriving stock (Eq, Show)

data MonitorControlReceipt = MonitorControlReceipt
  { revision :: !Int,
    tasksCancelled :: !Bool,
    pendingCancelled :: !Bool
  }
  deriving stock (Eq, Show)

data PendingPolicy = RetainPending | CancelPending deriving stock (Eq, Show)

parsePendingPolicy :: Text -> Maybe PendingPolicy
parsePendingPolicy "retain" = Just RetainPending
parsePendingPolicy "cancel" = Just CancelPending
parsePendingPolicy _ = Nothing

instance ToJSON MonitorControlReceipt where
  toJSON receipt =
    object
      [ "ok" .= True,
        "revision" .= receipt.revision,
        "admitted_tasks_cancelled" .= receipt.tasksCancelled,
        "pending_policy" .= (if receipt.pendingCancelled then "cancel" else "retain" :: Text)
      ]

monitorControlErrorText :: MonitorControlError -> Text
monitorControlErrorText = \case
  MonitorNotFound -> "monitor not found"
  MonitorOwnerRequired -> "monitor owner or administrator required"
  MonitorRevisionConflict -> "revision conflict"
  InvalidMonitorDefinition -> "invalid monitor definition"
  MonitorCallerFenced -> "monitor caller identity or execution lease is no longer valid"

armErrorText :: MonitorArmError -> Text
armErrorText = \case
  ArmedMonitorCapReached -> "本会话已达到 100 个 armed monitor 上限"
  ConditionMonitorCapReached -> "本会话已达到 25 个 condition monitor 上限"
  ArmingTurnOutsideConversation -> "arming turn 不属于当前会话"
  MonitorArmingForbidden -> "当前角色无权武装会主动发起回合的 monitor"
  ArmingCallerFenced -> "当前回合身份或执行租约已失效，不能创建提醒或 monitor"
