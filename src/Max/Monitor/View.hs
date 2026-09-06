-- | Monitor read models shared by query consumers and database row parsers.
module Max.Monitor.View (TimeMonitor (..), ArmedMonitor (..)) where

import Data.Int (Int64)
import Data.Text (Text)
import Data.Time (UTCTime)
import Max.Monitor.Types (MonitorRef)
import Max.Turn.Types (AgentTurnRef)

data ArmedMonitor = ArmedMonitor
  { amRef :: !MonitorRef,
    amGoal :: !Text,
    amTriggerKind :: !Text,
    amContinuationKind :: !Text,
    amNextFireAt :: !(Maybe UTCTime),
    amExpiresAt :: !(Maybe UTCTime),
    amFireCount :: !Int64,
    amMaxFireCount :: !(Maybe Int64),
    amCreatedAt :: !UTCTime
  }
  deriving stock (Show, Eq)

data TimeMonitor = TimeMonitor
  { tmRef :: !MonitorRef,
    tmGroupId :: !Int64,
    tmAuthorPrincipalId :: !(Maybe Int64),
    tmArmingTurn :: !(Maybe AgentTurnRef),
    tmText :: !Text,
    tmCron :: !(Maybe Text),
    tmNextFireAt :: !UTCTime,
    tmCreatedAt :: !UTCTime,
    tmFireCount :: !Int64,
    tmDeliveryAttempts :: !Int,
    tmNextAttemptAt :: !(Maybe UTCTime),
    tmLastError :: !(Maybe Text),
    tmParkedAt :: !(Maybe UTCTime)
  }
  deriving stock (Show, Eq)
