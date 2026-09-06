-- | Read-side task facts and presentation. The database returns bounded typed
-- columns; public handles, usage notes and JSON shape are constructed here.
module Max.Task.Query
  ( TaskSummary (..),
    TaskDetails (..),
    TaskCore (..),
    BrowserView (..),
    ProgressView (..),
    EventView (..),
    TaskUsage (..),
  )
where

import Data.Aeson (ToJSON (..), Value, object, (.=))
import Data.Aeson.Types (Pair)
import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime)
import Max.Browser.State (WorkspaceState, workspaceStateText)
import Max.Task.State (TaskStatus)
import Max.Task.Progress (ProgressDecision)
import Max.Task.Types (TaskProfile, profileName, taskHandle)

data TaskSummary = TaskSummary
  { taskId :: !Int64,
    revision :: !Int,
    objective :: !Text,
    status :: !TaskStatus,
    owner :: !Int64,
    parent :: !(Maybe Int64),
    deadline :: !UTCTime
  }
  deriving stock (Eq, Show)

summaryFields :: TaskSummary -> [Pair]
summaryFields task =
  [ "task" .= taskHandle task.taskId,
    "revision" .= task.revision,
    "objective" .= task.objective,
    "status" .= task.status,
    "owner" .= task.owner,
    "parent" .= task.parent,
    "deadline" .= task.deadline
  ]

instance ToJSON TaskSummary where toJSON = object . summaryFields

data TaskCore = TaskCore
  { summary :: !TaskSummary,
    profile :: !TaskProfile,
    grants :: !(Map Text Text),
    result :: !(Maybe Value),
    calls :: !Int,
    maxCalls :: !Int,
    rounds :: !Int,
    retryCount :: !Int,
    nextAttemptAt :: !(Maybe UTCTime),
    lastError :: !(Maybe Text),
    attempts :: !Int,
    pendingEvents :: !Int64
  }
  deriving stock (Eq, Show)

data BrowserView = BrowserView
  { state :: !WorkspaceState,
    generation :: !Int64,
    epoch :: !Int64,
    ownerTurn :: !(Maybe Int64),
    checkpointAt :: !(Maybe UTCTime),
    lastUsedAt :: !UTCTime
  }
  deriving stock (Eq, Show)

instance ToJSON BrowserView where
  toJSON view =
    object
      [ "state" .= workspaceStateText view.state,
        "generation" .= view.generation,
        "epoch" .= view.epoch,
        "owner_turn_id" .= view.ownerTurn,
        "checkpoint_at" .= view.checkpointAt,
        "last_used_at" .= view.lastUsedAt
      ]

data ProgressView = ProgressView
  { revision :: !Int,
    attempt :: !Int,
    version :: !Int64,
    body :: !Value,
    updatedAt :: !UTCTime,
    reviewDecision :: !(Maybe ProgressDecision),
    reviewedAt :: !(Maybe UTCTime)
  }
  deriving stock (Eq, Show)

instance ToJSON ProgressView where
  toJSON view =
    object
      [ "revision" .= view.revision,
        "attempt" .= view.attempt,
        "version" .= view.version,
        "body" .= view.body,
        "updated_at" .= view.updatedAt,
        "review_decision" .= view.reviewDecision,
        "reviewed_at" .= view.reviewedAt
      ]

data EventView = EventView
  { eventId :: !Int64,
    revision :: !Int,
    kind :: !Text,
    principal :: !(Maybe Int64),
    sourceMessage :: !(Maybe Int64),
    body :: !Text
  }
  deriving stock (Eq, Show)

instance ToJSON EventView where
  toJSON view =
    object
      [ "event_id" .= view.eventId,
        "revision" .= view.revision,
        "kind" .= view.kind,
        "author_principal_id" .= view.principal,
        "source_message_id" .= view.sourceMessage,
        "body" .= view.body
      ]

data TaskUsage = TaskUsage {promptTokens :: !Integer, completionTokens :: !Integer}
  deriving stock (Eq, Show)

instance ToJSON TaskUsage where
  toJSON usage =
    object
      [ "prompt_tokens" .= usage.promptTokens,
        "completion_tokens" .= usage.completionTokens,
        "accounting" .= ("observational; missing provider usage is unknown, not zero" :: Text)
      ]

data TaskDetails = TaskDetails
  { core :: !TaskCore,
    browser :: !(Maybe BrowserView),
    progress :: !(Maybe ProgressView),
    turns :: ![Int64],
    usage :: !TaskUsage,
    events :: ![EventView]
  }
  deriving stock (Eq, Show)

instance ToJSON TaskDetails where
  toJSON details =
    object $
      summaryFields core.summary
        <> [ "profile" .= profileName core.profile,
             "effective_tools" .= core.grants,
             "result" .= core.result,
             "calls_reserved" .= core.calls,
             "max_calls" .= core.maxCalls,
             "rounds_reserved" .= core.rounds,
             "retry_count" .= core.retryCount,
             "next_attempt_at" .= core.nextAttemptAt,
             "last_error" .= core.lastError,
             "attempts" .= core.attempts,
             "pending_events" .= core.pendingEvents,
             "browser" .= details.browser,
             "progress" .= details.progress,
             "turns" .= (if null details.turns then Nothing else Just ["t#" <> T.pack (show ordinal) | ordinal <- details.turns]),
             "usage" .= details.usage,
             "events" .= details.events
           ]
    where
      core = details.core
