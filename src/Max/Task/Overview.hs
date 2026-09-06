-- | Bounded durable-work read models. SQL supplies facts; Haskell owns the
-- public handles and JSON/prose projection consumed by tools and admin UI.
module Max.Task.Overview
  ( MonitorStatus (..),
    monitorStatusText,
    parseMonitorStatus,
    AdmissionState (..),
    admissionStateText,
    parseAdmissionState,
    MonitorDefinition (..),
    MonitorOccurrence (..),
    MonitorHistory (..),
    TaskOverview (..),
    ActiveTask (..),
    MonitorOverview (..),
    WorkOverview (..),
  )
where

import Data.Aeson (ToJSON (..), object, (.=))
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime)
import Max.Monitor.Policy (OccurrenceDisposition, OverlapPolicy, dispositionText, overlapPolicyText)
import Max.Task.State (TaskStatus, taskStatusText)
import Max.Task.Types (TaskProfile, profileName, taskHandle)

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

data TaskOverview = TaskOverview
  { taskId :: !Int64,
    groupId :: !Int64,
    owner :: !Int64,
    revision :: !Int,
    status :: !TaskStatus,
    profile :: !TaskProfile,
    objective :: !Text,
    calls :: !Int,
    maxCalls :: !Int,
    rounds :: !Int,
    maxRounds :: !Int,
    deadline :: !UTCTime,
    retryCount :: !Int,
    nextAttempt :: !(Maybe UTCTime),
    lastError :: !(Maybe Text),
    progress :: !(Maybe Text),
    failedNotifications :: !Int64,
    result :: !(Maybe Text)
  }
  deriving stock (Eq, Show)

instance ToJSON TaskOverview where
  toJSON view =
    object
      [ "handle" .= taskHandle view.taskId,
        "group_id" .= view.groupId,
        "owner_principal_id" .= view.owner,
        "revision" .= view.revision,
        "status" .= taskStatusText view.status,
        "profile" .= profileName view.profile,
        "objective" .= view.objective,
        "calls_reserved" .= view.calls,
        "max_calls" .= view.maxCalls,
        "rounds_reserved" .= view.rounds,
        "max_rounds" .= view.maxRounds,
        "deadline" .= view.deadline,
        "retry_count" .= view.retryCount,
        "next_attempt_at" .= view.nextAttempt,
        "last_error" .= view.lastError,
        "progress" .= view.progress,
        "failed_notifications" .= view.failedNotifications,
        "result" .= view.result
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

data WorkOverview = WorkOverview
  { tasks :: ![TaskOverview],
    monitors :: ![MonitorOverview],
    unresolvedRequests :: !Int64
  }
  deriving stock (Eq, Show)

instance ToJSON WorkOverview where
  toJSON view =
    object
      [ "tasks" .= view.tasks,
        "monitors" .= view.monitors,
        "unresolved_requests" .= view.unresolvedRequests
      ]
