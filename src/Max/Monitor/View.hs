-- | Bounded monitor status and history views. SQL supplies facts; Haskell owns the
-- public handles and JSON/prose projection consumed by tools and admin UI.
module Max.Monitor.View
  ( TimeMonitor (..),
    ArmedMonitor (..),
    MonitorStatus (..),
    monitorStatusText,
    parseMonitorStatus,
    AdmissionState (..),
    admissionStateText,
    parseAdmissionState,
    MonitorDefinition (..),
    MonitorOccurrence (..),
    MonitorHistory (..),
    ActiveTask (..),
    MonitorOverview (..),
  )
where

import Data.Aeson (ToJSON (..), object, (.=))
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime)
import Max.Monitor.Policy (OccurrenceDisposition, OverlapPolicy, dispositionText, overlapPolicyText)
import Max.Monitor.Types (MonitorRef)
import Max.Task.State (TaskStatus, taskStatusText)
import Max.Task.Types (TaskProfile, profileName, taskHandle)
import Max.Turn.Types (AgentTurnRef)

data MonitorStatus = Armed | Fired | MonitorCancelled | Expired deriving stock (Eq, Show)

monitorStatusText :: MonitorStatus -> Text
monitorStatusText = \case
  Armed -> "armed"
  Fired -> "fired"
  MonitorCancelled -> "cancelled"
  Expired -> "expired"

parseMonitorStatus :: Text -> Maybe MonitorStatus
parseMonitorStatus = \case
  "armed" -> Just Armed
  "fired" -> Just Fired
  "cancelled" -> Just MonitorCancelled
  "expired" -> Just Expired
  _ -> Nothing

data AdmissionState = PendingAdmission | DispatchedAdmission deriving stock (Eq, Show)

admissionStateText :: AdmissionState -> Text
admissionStateText PendingAdmission = "pending"
admissionStateText DispatchedAdmission = "dispatched"

parseAdmissionState :: Text -> Maybe AdmissionState
parseAdmissionState "pending" = Just PendingAdmission
parseAdmissionState "dispatched" = Just DispatchedAdmission
parseAdmissionState _ = Nothing

monitorHandle :: Int64 -> Text
monitorHandle ordinal = "m#" <> T.pack (show ordinal)

data MonitorDefinition = MonitorDefinition
  { ordinal :: !Int64,
    revision :: !Int,
    goal :: !Text,
    profile :: !TaskProfile,
    status :: !MonitorStatus,
    overlap :: !OverlapPolicy,
    queueLimit :: !Int,
    changeOnly :: !Bool,
    nextFire :: !(Maybe UTCTime)
  }
  deriving stock (Eq, Show)

data MonitorOccurrence = MonitorOccurrence
  { fireId :: !Int64,
    revision :: !Int,
    scheduledAt :: !UTCTime,
    disposition :: !OccurrenceDisposition,
    taskId :: !(Maybe Int64),
    coalescedInto :: !(Maybe Int64),
    admission :: !AdmissionState,
    evidence :: !Text,
    lastError :: !(Maybe Text)
  }
  deriving stock (Eq, Show)

instance ToJSON MonitorOccurrence where
  toJSON view =
    object
      [ "fire_id" .= view.fireId,
        "definition_revision" .= view.revision,
        "scheduled_at" .= view.scheduledAt,
        "disposition" .= dispositionText view.disposition,
        "task_id" .= view.taskId,
        "coalesced_into" .= view.coalescedInto,
        "admission_state" .= admissionStateText view.admission,
        "evidence" .= view.evidence,
        "last_error" .= view.lastError
      ]

data MonitorHistory = MonitorHistory
  { definition :: !MonitorDefinition,
    fires :: ![MonitorOccurrence]
  }
  deriving stock (Eq, Show)

instance ToJSON MonitorHistory where
  toJSON view =
    object
      [ "handle" .= monitorHandle view.definition.ordinal,
        "revision" .= view.definition.revision,
        "goal" .= view.definition.goal,
        "profile" .= profileName view.definition.profile,
        "status" .= monitorStatusText view.definition.status,
        "overlap" .= overlapPolicyText view.definition.overlap,
        "queue_limit" .= view.definition.queueLimit,
        "change_only" .= view.definition.changeOnly,
        "next_fire" .= view.definition.nextFire,
        "fires" .= view.fires
      ]

data ActiveTask = ActiveTask
  { taskId :: !Int64,
    status :: !TaskStatus
  }
  deriving stock (Eq, Show)

data MonitorOverview = MonitorOverview
  { ordinal :: !Int64,
    groupId :: !Int64,
    revision :: !Int,
    status :: !MonitorStatus,
    profile :: !TaskProfile,
    changeOnly :: !Bool,
    overlap :: !OverlapPolicy,
    queueLimit :: !Int,
    nextFire :: !(Maybe UTCTime),
    coalesced :: !Int64,
    overflow :: !Int64,
    lastError :: !(Maybe Text),
    activeTasks :: ![ActiveTask]
  }
  deriving stock (Eq, Show)

instance ToJSON MonitorOverview where
  toJSON view =
    object
      [ "handle" .= monitorHandle view.ordinal,
        "group_id" .= view.groupId,
        "definition_revision" .= view.revision,
        "status" .= monitorStatusText view.status,
        "task_profile" .= profileName view.profile,
        "change_only" .= view.changeOnly,
        "overlap_policy" .= overlapPolicyText view.overlap,
        "queue_limit" .= view.queueLimit,
        "next_fire_at" .= view.nextFire,
        "coalesced" .= view.coalesced,
        "overflow" .= view.overflow,
        "last_error" .= view.lastError,
        "active_tasks" .= activeTasksText view.activeTasks
      ]

activeTasksText :: [ActiveTask] -> Maybe Text
activeTasksText [] = Nothing
activeTasksText tasks = Just (T.intercalate ", " [taskHandle task.taskId <> " " <> taskStatusText task.status | task <- tasks])

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
    tmFireCount :: !Int64
  }
  deriving stock (Show, Eq)
