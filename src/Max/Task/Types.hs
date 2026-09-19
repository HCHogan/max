module Max.Task.Types
  ( JobRun (..),
    JobSpec (..),
    JobMonitor (..),
    JobView (..),
    JobResult (..),
    JobWait (..),
    JobCommand (..),
    TaskProfile (..),
    profileName,
    taskProfileNames,
    parseProfile,
    taskGrants,
    taskHandle,
    parseTaskHandle,
  )
where

import Data.Aeson (ToJSON (..), Value, object, (.=))
import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime)
import Max.Monitor.Types (MonitorFireId, MonitorId)
import Max.Platform.Types (CanonicalMessageId, PrincipalId)
import Max.Skill.Contract (Contract)
import Max.Task.State (TaskStatus)
import OneBot.Types (GroupId)
import Text.Read (readMaybe)

data TaskProfile = Research | Browser | Sandbox
  deriving stock (Eq, Show)

profileName :: TaskProfile -> Text
profileName Research = "research"
profileName Browser = "browser"
profileName Sandbox = "sandbox"

taskProfileNames :: [Text]
taskProfileNames = map profileName [Research, Browser, Sandbox]

parseProfile :: Text -> Maybe TaskProfile
parseProfile "research" = Just Research
parseProfile "browser" = Just Browser
parseProfile "sandbox" = Just Sandbox
-- Stored tasks, monitor snapshots and old workflow programs retain this name.
-- Decode it into the one shell profile; new writes always use "sandbox".
parseProfile "operations" = Just Sandbox
parseProfile _ = Nothing

taskGrants :: TaskProfile -> Map Text Text -> Map Text Text
taskGrants profile parent = Map.filterWithKey (\name _ -> name `elem` allowed) parent
  where
    allowed =
      [ "web_search",
        "get_message_by_id",
        "context_search",
        "context_expand",
        "view_forward",
        "memory_list",
        "view_image",
        "view_video",
        "view_avatar",
        "view_bilibili",
        "use_skill",
        "task_start",
        "task_status",
        "task_list",
        "task_steer",
        "task_wait"
      ]
        <> case profile of
          Research -> []
          Browser ->
            ["browser", "view_zhihu"]
          Sandbox ->
            [ "sandbox_list",
              "sandbox_create",
              "sandbox_destroy",
              "sandbox_exec",
              "sandbox_read_file",
              "sandbox_write_file",
              "import_file_to_sandbox",
              "nix_search"
            ]

taskHandle :: Int64 -> Text
taskHandle identifier = "task#" <> T.pack (show identifier)

parseTaskHandle :: Text -> Maybe Int64
parseTaskHandle raw = do
  digits <- T.stripPrefix "task#" (T.strip raw)
  if T.null digits || T.any (\character -> character < '0' || character > '9') digits
    then Nothing
    else do
      identifier <- readMaybe (T.unpack digits)
      if identifier > 0 then Just identifier else Nothing

-- | A replacement keeps the public handle; old workers retain an obsolete run.
data JobRun = JobRun {jobId :: !Int64, generation :: !Int}
  deriving stock (Eq, Ord, Show)

data JobMonitor = JobMonitor {definitionId :: !MonitorId, fireId :: !MonitorFireId}
  deriving stock (Eq, Show)

data JobSpec = JobSpec
  { group :: !GroupId,
    principal :: !PrincipalId,
    source :: !CanonicalMessageId,
    objective :: !Text,
    profile :: !TaskProfile,
    grants :: !(Map Text Text),
    inputs :: !Value,
    parent :: !(Maybe JobRun),
    contract :: !(Maybe Contract),
    delegated :: !Bool,
    monitor :: !(Maybe JobMonitor),
    browserProfile :: !(Maybe (Int64, Int64)),
    deadline :: !UTCTime
  }
  deriving stock (Eq, Show)

data JobResult = JobResult {text :: !Text, payload :: !(Maybe Value)}
  deriving stock (Eq, Show)

instance ToJSON JobResult where
  toJSON result = object ["text" .= result.text, "payload" .= result.payload]

data JobView = JobView
  { run :: !JobRun,
    spec :: !JobSpec,
    status :: !TaskStatus,
    progress :: !(Maybe Text),
    result :: !(Maybe JobResult),
    calls :: !Int,
    rounds :: !Int,
    created :: !UTCTime,
    browserAllowed :: !Bool
  }
  deriving stock (Eq, Show)

instance ToJSON JobView where
  toJSON job =
    object
      [ "task" .= taskHandle job.run.jobId,
        "objective" .= job.spec.objective,
        "profile" .= profileName job.spec.profile,
        "owner" .= job.spec.principal,
        "group_id" .= job.spec.group,
        "parent" .= (taskHandle . (.jobId) <$> job.spec.parent),
        "status" .= job.status,
        "progress" .= job.progress,
        "result" .= job.result,
        "calls" .= job.calls,
        "model_rounds" .= job.rounds,
        "deadline" .= job.spec.deadline
      ]

data JobWait = ChildrenFinished ![JobView] | FeedbackPending
  deriving stock (Eq, Show)

data JobCommand = SteerJob !Text | ReplaceJob !Text | CancelJob !Text
  deriving stock (Eq, Show)
