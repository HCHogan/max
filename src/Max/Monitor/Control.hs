-- | Monitor commands, policies and failure vocabulary. No storage authority.
module Max.Monitor.Control
  ( MonitorCommand (..),
    MonitorControlError (..),
    MonitorControlReceipt (..),
    MonitorArmError (..),
    HttpMonitorSpec (..),
    PendingPolicy (..),
    parsePendingPolicy,
    monitorControlErrorText,
    armErrorText,
  )
where

import Data.Aeson (ToJSON (..), object, (.=))
import Data.Int (Int64)
import Data.Text (Text)
import Data.Time (UTCTime)
import Max.Monitor.Policy (OverlapPolicy)
import Max.Task.Types (TaskProfile)

data HttpMonitorSpec = HttpMonitorSpec
  { goal :: !Text,
    profile :: !TaskProfile,
    cooldownSeconds :: !Int,
    expiresAt :: !(Maybe UTCTime),
    maxFires :: !(Maybe Int64)
  }
  deriving stock (Eq, Show)

data MonitorArmError
  = ArmedMonitorCapReached
  | ConditionMonitorCapReached
  | ArmingTurnOutsideConversation
  | MonitorArmingForbidden
  | ArmingCallerFenced
  | HttpMonitorsUnavailable
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
  MonitorNotFound -> "这个会话里没有这条自动化"
  MonitorOwnerRequired -> "只有创建者或管理员能修改或取消这条自动化"
  MonitorRevisionConflict -> "revision 已变化，先用 automation_history 查最新 revision"
  InvalidMonitorDefinition -> "自动化定义无效：说明不能为空、不超过 40000 字，queue_limit 在 1..160"
  MonitorCallerFenced -> "当前回合身份或运行状态已失效，不能修改自动化"

armErrorText :: MonitorArmError -> Text
armErrorText = \case
  ArmedMonitorCapReached -> "本会话已达到 100 条生效中自动化的上限"
  ConditionMonitorCapReached -> "本会话已达到 25 条消息/webhook 自动化的上限"
  ArmingTurnOutsideConversation -> "创建回合不属于当前会话"
  MonitorArmingForbidden -> "只有群管理员能创建按消息或 webhook 触发的自动化；定时触发任何人都能建"
  ArmingCallerFenced -> "当前回合身份或运行状态已失效，不能创建自动化"
  HttpMonitorsUnavailable -> "webhook 自动化未启用：需要配置 admin.webhook_base_url"
