module Max.Task.Types
  ( JobRun (..),
    JobSpec (..),
    JobMonitor (..),
    JobView (..),
    JobResult (..),
    JobUsage (..),
    emptyJobUsage,
    addJobUsage,
    jobUsageLine,
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
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (NominalDiffTime, UTCTime, diffUTCTime)
import Max.LLM.Types (CallCost (..), TokenUsage (..))
import Max.Monitor.Types (MonitorFireId, MonitorId)
import Max.Platform.Types (CanonicalMessageId, PrincipalId)
import Max.Skill.Contract (Contract)
import Max.Task.State (TaskStatus)
import OneBot.Types (GroupId)
import Text.Printf (printf)
import Text.Read (readMaybe)

data TaskProfile = Basic | Browser | Sandbox
  deriving stock (Eq, Show)

profileName :: TaskProfile -> Text
profileName Basic = "basic"
profileName Browser = "browser"
profileName Sandbox = "sandbox"

taskProfileNames :: [Text]
taskProfileNames = map profileName [Basic, Browser, Sandbox]

parseProfile :: Text -> Maybe TaskProfile
parseProfile "basic" = Just Basic
parseProfile "browser" = Just Browser
parseProfile "sandbox" = Just Sandbox
-- Historical snapshots and workflow programs retain the former names.
parseProfile "research" = Just Basic
parseProfile "operations" = Just Sandbox
parseProfile _ = Nothing

taskGrants :: TaskProfile -> Map Text Text -> Map Text Text
taskGrants profile parent = Map.filterWithKey (\name _ -> name `elem` allowed) parent
  where
    allowed =
      [ "web_search",
        "context_search",
        "context_resume",
        "context_read",
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
          Basic -> []
          Browser ->
            ["browser", "view_zhihu"]
          Sandbox ->
            [ "sandbox_destroy",
              "sandbox_exec",
              "read_file",
              "write_file",
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

-- | Model spend of a job and all its descendants, booked as each completion
-- returns.
data JobUsage = JobUsage
  { modelCalls :: !Int,
    promptTokens :: !Int,
    cachedPromptTokens :: !Int,
    completionTokens :: !Int,
    -- | Estimated cost per currency; calls on unpriced profiles add none.
    costs :: !(Map Text Double),
    unpricedCalls :: !Int
  }
  deriving stock (Eq, Show)

emptyJobUsage :: JobUsage
emptyJobUsage = JobUsage 0 0 0 0 Map.empty 0

addJobUsage :: TokenUsage -> JobUsage -> JobUsage
addJobUsage usage total =
  JobUsage
    { modelCalls = total.modelCalls + 1,
      promptTokens = total.promptTokens + max 0 usage.usagePrompt,
      cachedPromptTokens = total.cachedPromptTokens + max 0 (maybe 0 (min usage.usagePrompt) usage.usageCachedPrompt),
      completionTokens = total.completionTokens + max 0 usage.usageCompletion,
      costs = maybe total.costs (\cost -> Map.insertWith (+) cost.currency cost.amount total.costs) usage.usageCost,
      unpricedCalls = total.unpricedCalls + maybe 1 (const 0) usage.usageCost
    }

instance ToJSON JobUsage where
  toJSON usage =
    object
      [ "model_calls" .= usage.modelCalls,
        "prompt_tokens" .= usage.promptTokens,
        "cached_prompt_tokens" .= usage.cachedPromptTokens,
        "completion_tokens" .= usage.completionTokens,
        "cost" .= usage.costs,
        "unpriced_calls" .= usage.unpricedCalls
      ]

data JobView = JobView
  { run :: !JobRun,
    spec :: !JobSpec,
    status :: !TaskStatus,
    progress :: !(Maybe Text),
    result :: !(Maybe JobResult),
    calls :: !Int,
    rounds :: !Int,
    created :: !UTCTime,
    browserAllowed :: !Bool,
    usage :: !JobUsage,
    finished :: !(Maybe UTCTime)
  }
  deriving stock (Eq, Show)

-- | The spend and wall time of a finished job, for its report.
jobUsageLine :: JobView -> Text
jobUsageLine job =
  "用量："
    <> T.intercalate
      "，"
      ( tokens
          <> ["用时 " <> elapsed (maybe 0 (`diffUTCTime` job.created) job.finished)]
          <> ["预估费用 " <> T.intercalate " + " (map money (Map.toList used.costs)) <> unpriced | not (Map.null used.costs)]
      )
  where
    used = job.usage
    tokens
      | used.modelCalls == 0 = ["没有调用模型"]
      | otherwise =
          [ "模型调用 " <> count used.modelCalls <> " 次",
            "输入 " <> count used.promptTokens <> " tokens" <> (if used.cachedPromptTokens > 0 then "（缓存命中 " <> count used.cachedPromptTokens <> "）" else ""),
            "输出 " <> count used.completionTokens <> " tokens"
          ]
    unpriced
      | used.unpricedCalls > 0 = "（另有 " <> count used.unpricedCalls <> " 次调用未配置价格）"
      | otherwise = ""

-- | 12345 → "1.2万"; counts below ten thousand stay exact.
count :: Int -> Text
count n
  | n >= 100000000 = scaled 100000000 "亿"
  | n >= 10000 = scaled 10000 "万"
  | otherwise = T.pack (show n)
  where
    scaled unit suffix =
      let value = fromIntegral n / fromIntegral (unit :: Int) :: Double
          digits = T.pack (printf "%.1f" value)
       in fromMaybe digits (T.stripSuffix ".0" digits) <> suffix

elapsed :: NominalDiffTime -> Text
elapsed duration
  | total < 60 = T.pack (show total) <> " 秒"
  | total < 3600 = T.pack (show (total `div` 60)) <> " 分 " <> T.pack (show (total `mod` 60)) <> " 秒"
  | otherwise = T.pack (show (total `div` 3600)) <> " 小时 " <> T.pack (show ((total `mod` 3600) `div` 60)) <> " 分"
  where
    total = max 0 (round duration) :: Int

money :: (Text, Double) -> Text
money (currency, amount) = case T.toUpper currency of
  "USD" -> "$" <> figure
  "CNY" -> "¥" <> figure
  "RMB" -> "¥" <> figure
  _ -> figure <> " " <> currency
  where
    figure
      | amount <= 0 = "0"
      | amount < 0.0001 = "<0.0001"
      | amount < 1 = T.pack (printf "%.4f" amount)
      | otherwise = T.pack (printf "%.2f" amount)

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
        "usage" .= job.usage,
        "created_at" .= job.created,
        "finished_at" .= job.finished,
        "deadline" .= job.spec.deadline
      ]

data JobWait = ChildrenFinished ![JobView] | FeedbackPending
  deriving stock (Eq, Show)

data JobCommand = SteerJob !Text | ReplaceJob !Text | CancelJob !Text
  deriving stock (Eq, Show)
