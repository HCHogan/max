module JobFixture (RunningJob (..), seed, runningJob, launchNext, insertOccurrence, draft) where

import Control.Monad (void)
import Data.Aeson (Value (Null))
import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Text (Text)
import Data.Time (addUTCTime, getCurrentTime)
import Database.PostgreSQL.Simple (Only (..))
import Effectful.PostgreSQL (query)
import Helpers (insertRawMessage, testTime, withDb)
import Max.DB.AgentTurn (startAgentTurn)
import Max.DB.Codec (databaseNow)
import Max.DB.Connection (DbPool)
import Max.DB.Job (allocateJobId)
import Max.DB.Monitor.Occurrence (OccurrenceDraft (..), recordOccurrence)
import Max.IR (Body (..), Node (NText))
import Max.Jobs
import Max.Monitor.Types (MonitorRef (..))
import Max.Platform.Store (OutboundDraft (..))
import Max.Platform.Types
import Max.Task.Types
import Max.Tasks (TaskRegistry, TurnRuntime, beginDurableTurnRuntime, newTaskRegistry)
import Max.Turn.Types
import OneBot.Types (GroupId (..), UserId (..))

data RunningJob = RunningJob {jobs :: Jobs, tasks :: TaskRegistry, job :: JobView, turn :: AgentTurnRef, runtime :: TurnRuntime}

seed :: DbPool -> Int64 -> Int64 -> IO (AgentTurnRef, CanonicalMessageId, PrincipalId)
seed pool group user = do
  [Only count] <- withDb pool (query "SELECT count(*) FROM messages" ())
  message <- insertRawMessage pool (100000 + (count :: Int64)) group user 99 testTime Nothing "explicit request"
  [Only principal] <- withDb pool (query "SELECT author_principal_id FROM messages WHERE canonical_message_id=?" (Only message))
  turn <- withDb pool (startAgentTurn (GroupId group) (CanonicalMessageId message) (PrincipalId principal))
  pure (turn, CanonicalMessageId message, PrincipalId principal)

runningJob :: DbPool -> TaskProfile -> Map Text Text -> IO RunningJob
runningJob pool profile grants = do
  (_, message, actor) <- seed pool 900 1
  tasks <- newTaskRegistry
  jobs <- newJobs tasks
  now <- getCurrentTime
  identifier <- withDb pool allocateJobId
  let spec = JobSpec {group = GroupId 900, principal = actor, source = message, objective = "bounded work", profile, grants, inputs = Null, parent = Nothing, contract = Nothing, delegated = False, monitor = Nothing, browserProfile = Nothing, deadline = addUTCTime 3600 now}
  Right _ <- admitJob jobs Nothing identifier spec
  launchNext pool tasks jobs

launchNext :: DbPool -> TaskRegistry -> Jobs -> IO RunningJob
launchNext pool tasks jobs = do
  LaunchJob job <- takeJobWork jobs
  turn <- withDb pool (startAgentTurn job.spec.group job.spec.source job.spec.principal)
  runtime <- beginDurableTurnRuntime tasks turn job.spec.group (UserId 1) (Just job.spec.source)
  attached <- attachJobTurn jobs job.run turn
  if attached then pure (RunningJob jobs tasks job turn runtime) else fail "job fixture attach failed"

insertOccurrence :: DbPool -> MonitorRef -> Text -> IO ()
insertOccurrence pool monitor key = void $ withDb pool $ do
  now <- databaseNow
  recordOccurrence monitor.mrMonitorId (OccurrenceDraft key now Nothing "" False)

draft :: AgentTurnRef -> OutboundDraft
draft turn = OutboundDraft {legacyConversationId = 900, transcriptKind = "chat", sourceCanonicalMessageId = Nothing, canonicalBody = Body [NText "task report"], replyToCanonicalMessageId = Nothing, turnOutputLink = Just (TurnOutputLink turn.atrTurnId 0), monitorFireId = Nothing}
