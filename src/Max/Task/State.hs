-- | Task decisions are host-owned values. PostgreSQL stores their results;
-- neither JSON report fields nor an error's display text drive transitions.
module Max.Task.State
  ( TaskStatus (..),
    taskStatusText,
    parseTaskStatus,
    taskIsLive,
    ReportStatus (..),
    reportStatusText,
    FailureKind (..),
    TaskReport (..),
    parseTaskReport,
    reportTaskStatus,
    RequestDisposition (..),
    dispositionText,
    parseDisposition,
    SettlementFacts (..),
    TaskSettlement (..),
    decideSettlement,
    retryDelaySeconds,
    TaskOperation (..),
    parseTaskOperation,
    taskOperationText,
    TaskControlError (..),
    renderTaskControlError,
    TaskControlReceipt (..),
    TaskControlFacts (..),
    TaskControlDecision (..),
    decideTaskControl,
  )
where

import Data.Aeson
import Data.Aeson.Types (Parser, parseEither)
import Data.ByteString.Lazy qualified as LBS
import Data.Int (Int64)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime, addUTCTime)

data TaskStatus = Queued | Running | Waiting | Retrying | Succeeded | Partial | Failed | Cancelled | BudgetExhausted
  deriving stock (Eq, Show)

taskStatusText :: TaskStatus -> Text
taskStatusText = \case
  Queued -> "queued"
  Running -> "running"
  Waiting -> "waiting"
  Retrying -> "retrying"
  Succeeded -> "succeeded"
  Partial -> "partial"
  Failed -> "failed"
  Cancelled -> "cancelled"
  BudgetExhausted -> "budget_exhausted"

parseTaskStatus :: Text -> Maybe TaskStatus
parseTaskStatus = \case
  "queued" -> Just Queued
  "running" -> Just Running
  "waiting" -> Just Waiting
  "retrying" -> Just Retrying
  "succeeded" -> Just Succeeded
  "partial" -> Just Partial
  "failed" -> Just Failed
  "cancelled" -> Just Cancelled
  "budget_exhausted" -> Just BudgetExhausted
  _ -> Nothing

taskIsLive :: TaskStatus -> Bool
taskIsLive status = status `elem` [Queued, Running, Waiting, Retrying]

instance ToJSON TaskStatus where
  toJSON = String . taskStatusText

instance FromJSON TaskStatus where
  parseJSON = withText "task status" $ maybe (fail "unknown task status") pure . parseTaskStatus

data ReportStatus = ReportSucceeded | ReportPartial | ReportWaiting | ReportFailed | ReportBudgetExhausted | ReportCancelled
  deriving stock (Eq, Show)

reportStatusText :: ReportStatus -> Text
reportStatusText = \case
  ReportSucceeded -> "succeeded"
  ReportPartial -> "partial"
  ReportWaiting -> "waiting"
  ReportFailed -> "failed"
  ReportBudgetExhausted -> "budget_exhausted"
  ReportCancelled -> "cancelled"

instance ToJSON ReportStatus where
  toJSON = String . reportStatusText

instance FromJSON ReportStatus where
  parseJSON = withText "report status" $ \case
    "succeeded" -> pure ReportSucceeded
    "partial" -> pure ReportPartial
    "waiting" -> pure ReportWaiting
    "failed" -> pure ReportFailed
    "budget_exhausted" -> pure ReportBudgetExhausted
    "cancelled" -> pure ReportCancelled
    _ -> fail "invalid task report status"

data FailureKind = Permanent | Transient deriving stock (Eq, Show)

instance ToJSON FailureKind where
  toJSON Permanent = String "permanent"
  toJSON Transient = String "transient"

instance FromJSON FailureKind where
  parseJSON = withText "failure kind" $ \case
    "permanent" -> pure Permanent
    "transient" -> pure Transient
    _ -> fail "invalid failure kind"

data TaskReport = TaskReport
  { status :: !ReportStatus,
    summary :: !Text,
    evidence :: ![Text],
    unresolved :: ![Text],
    failureKind :: !(Maybe FailureKind),
    observation :: !(Maybe Value)
  }
  deriving stock (Eq, Show)

instance ToJSON TaskReport where
  toJSON report =
    object $
      [ "status" .= report.status,
        "summary" .= report.summary,
        "evidence" .= report.evidence,
        "unresolved" .= report.unresolved
      ]
        <> ["failure_kind" .= kind | Just kind <- [report.failureKind]]
        <> ["observation" .= value | Just value <- [report.observation]]

instance FromJSON TaskReport where
  -- Stored host outcomes may include cancellation, exhaustion, or extra
  -- reconciliation notes. Model limits belong to parseTaskReport, not reads.
  parseJSON = withObject "task report" $ \fields ->
    TaskReport
      <$> fields .: "status"
      <*> fields .: "summary"
      <*> fields .:? "evidence" .!= []
      <*> fields .:? "unresolved" .!= []
      <*> fields .:? "failure_kind"
      <*> fields .:? "observation"

parseTaskReport :: Value -> Either Text TaskReport
parseTaskReport value = do
  report <- either (Left . T.pack) Right (parseEither (parseJSON :: Value -> Parser TaskReport) value)
  if report.status `notElem` [ReportSucceeded, ReportPartial, ReportWaiting, ReportFailed]
    then Left "only the host may report cancellation or exhausted budgets"
    else
      if T.null (T.strip report.summary)
        || T.length report.summary > 40000
        || length report.evidence > 80
        || length report.unresolved > 80
        || LBS.length (encode value) > 80000
        then Left "invalid task report fields or size"
        else Right report

reportTaskStatus :: ReportStatus -> TaskStatus
reportTaskStatus = \case
  ReportSucceeded -> Succeeded
  ReportPartial -> Partial
  ReportWaiting -> Waiting
  ReportFailed -> Failed
  ReportBudgetExhausted -> BudgetExhausted
  ReportCancelled -> Cancelled

data RequestDisposition = RequestPending | RequestDelegated | RequestAnswered | RequestWaiting | RequestDeclined | RequestFailed | RequestCancelled
  deriving stock (Eq, Show)

dispositionText :: RequestDisposition -> Text
dispositionText = \case
  RequestPending -> "pending"
  RequestDelegated -> "delegated"
  RequestAnswered -> "answered"
  RequestWaiting -> "waiting"
  RequestDeclined -> "declined"
  RequestFailed -> "failed"
  RequestCancelled -> "cancelled"

parseDisposition :: Text -> Maybe RequestDisposition
parseDisposition = \case
  "pending" -> Just RequestPending
  "delegated" -> Just RequestDelegated
  "answered" -> Just RequestAnswered
  "waiting" -> Just RequestWaiting
  "declined" -> Just RequestDeclined
  "failed" -> Just RequestFailed
  "cancelled" -> Just RequestCancelled
  _ -> Nothing

-- | Facts read under the settlement transaction's ownership locks. The
-- caller checks revision/attempt/lease before applying the decision.
data SettlementFacts = SettlementFacts
  { now :: !UTCTime,
    deadline :: !UTCTime,
    attempt :: !Int,
    retryCount :: !Int,
    budgetExhausted :: !Bool,
    retryable :: !Bool,
    ambiguousEffects :: !Bool,
    pendingInput :: !Bool,
    report :: !(Maybe TaskReport),
    abortReason :: !(Maybe Text)
  }
  deriving stock (Eq, Show)

data TaskSettlement = TaskSettlement
  { status :: !TaskStatus,
    report :: !TaskReport,
    retryAt :: !(Maybe UTCTime)
  }
  deriving stock (Eq, Show)

decideSettlement :: SettlementFacts -> TaskSettlement
decideSettlement facts
  | canRetry && facts.ambiguousEffects =
      finish Waiting $
        reported {status = ReportWaiting, unresolved = reported.unresolved <> ["An external effect is ambiguous; reconcile it before retrying"]}
  | canRetry = TaskSettlement Retrying reported (Just (addUTCTime (fromIntegral (retryDelaySeconds facts.retryCount)) facts.now))
  | otherwise = finish terminal reported
  where
    reported = case facts.report of
      Just value -> value
      Nothing ->
        TaskReport
          (if facts.budgetExhausted || facts.deadline <= facts.now then ReportBudgetExhausted else ReportFailed)
          (fromMaybe "execution ended without task_finish" facts.abortReason)
          []
          []
          Nothing
          Nothing
    canRetry =
      reported.status == ReportFailed
        && (facts.retryable || reported.failureKind == Just Transient)
        && facts.attempt < 40
        && facts.deadline > addUTCTime 5 facts.now
        && not facts.budgetExhausted
    terminal = case facts.report of
      Nothing | facts.budgetExhausted || facts.deadline <= facts.now -> BudgetExhausted
      _ -> reportTaskStatus reported.status
    finish next value = TaskSettlement (if facts.pendingInput then Queued else next) value Nothing

retryDelaySeconds :: Int -> Int
retryDelaySeconds retries = min 300 (5 * 2 ^ min 6 (max 0 retries))

-- | Parsed once at the external command boundary; arbitrary tool JSON cannot
-- invent a new state transition.
data TaskOperation = Steer | Replace | Cancel deriving stock (Eq, Show)

parseTaskOperation :: Text -> Maybe TaskOperation
parseTaskOperation = \case
  "steer" -> Just Steer
  "replace" -> Just Replace
  "cancel" -> Just Cancel
  _ -> Nothing

taskOperationText :: TaskOperation -> Text
taskOperationText = \case
  Steer -> "steer"
  Replace -> "replace"
  Cancel -> "cancel"

data TaskControlError
  = TaskNotFound
  | InvalidEventProvenance
  | InvalidTaskNote
  | TaskOwnerRequired
  | TaskRevisionConflict !Int
  | TaskResumeOwnerRequired
  | TaskClosed
  | TaskCallerFenced
  | TaskChildScopeRequired
  deriving stock (Eq, Show)

renderTaskControlError :: TaskControlError -> Text
renderTaskControlError = \case
  TaskNotFound -> "task not found in this conversation"
  InvalidEventProvenance -> "invalid event provenance"
  InvalidTaskNote -> "note must contain 1..40000 characters"
  TaskOwnerRequired -> "only the initiator or an administrator can change this task"
  TaskRevisionConflict _ -> "revision conflict"
  TaskResumeOwnerRequired -> "only the initiator or an administrator can resume completed work"
  TaskClosed -> "task is closed; start a new authorized task"
  TaskCallerFenced -> "current execution no longer owns this operation"
  TaskChildScopeRequired -> "only a current parent may steer its direct child"

data TaskControlReceipt = TaskControlReceipt
  { taskId :: !Int64,
    revision :: !Int
  }
  deriving stock (Eq, Show)

-- | Authority and version facts captured under the commit lock.
instance ToJSON TaskControlReceipt where
  toJSON receipt =
    object
      [ "queued" .= True,
        "task_id" .= receipt.taskId,
        "revision" .= receipt.revision,
        "note" .= ("durably recorded; not yet acted upon" :: Text)
      ]

data TaskControlFacts = TaskControlFacts
  { controlStatus :: !TaskStatus,
    controlRevision :: !Int,
    controlsOwner :: !Bool,
    validProvenance :: !Bool,
    repeatedEvent :: !Bool
  }
  deriving stock (Eq, Show)

data TaskControlDecision = ReplayControl | ApplyControl deriving stock (Eq, Show)

decideTaskControl :: TaskOperation -> Maybe Int -> Text -> TaskControlFacts -> Either TaskControlError TaskControlDecision
decideTaskControl operation revision note facts
  | not facts.validProvenance = Left InvalidEventProvenance
  | T.null trimmed || T.length trimmed > 40000 = Left InvalidTaskNote
  | operation /= Steer && not facts.controlsOwner = Left TaskOwnerRequired
  | facts.repeatedEvent = Right ReplayControl
  | operation == Replace && revision /= Just facts.controlRevision = Left (TaskRevisionConflict facts.controlRevision)
  | operation == Steer && facts.controlStatus `notElem` [Queued, Running, Retrying] && not facts.controlsOwner = Left TaskResumeOwnerRequired
  | operation == Steer && facts.controlStatus `elem` [Cancelled, BudgetExhausted] = Left TaskClosed
  | otherwise = Right ApplyControl
  where
    trimmed = T.strip note
