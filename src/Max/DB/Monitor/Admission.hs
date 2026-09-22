-- | Validate a trigger and start an ordinary in-process Job.
module Max.DB.Monitor.Admission (MonitorAdmission (..), MonitorAdmissionError (..), admitMonitorTaskWithin, monitorTaskProfile, recordMonitorResult, markMonitorJobStarted) where

import Control.Monad (join, void, when)
import Data.Aeson (Value, object, withObject, (.:?), (.=))
import Data.Aeson.Types (parseMaybe)
import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust, isNothing, listToMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime, addUTCTime)
import Database.PostgreSQL.Simple.FromRow (FromRow (..), field)
import Database.PostgreSQL.Simple.Types (Only (..))
import Effectful
import Effectful.PostgreSQL (WithConnection, execute, query)
import Max.DB.Codec (databaseNow, enumField, jsonField, jsonText)
import Max.DB.Job (allocateJobId)
import Max.DB.Monitor.Occurrence
import Max.DB.Transaction (withTransaction)
import Max.Monitor.Policy
import Max.Monitor.Types (MonitorFireId (..), MonitorId)
import Max.Platform.Types (CanonicalMessageId (..), PrincipalId (..))
import Max.Skill.Contract (Contract, parseContract)
import Max.Task.State (TaskStatus (..))
import Max.Task.Types
import OneBot.Types (GroupId (..))

data MonitorAdmission = MonitorTaskAdmitted !Int64 !JobSpec | MonitorAlreadyDispatched | MonitorCoalesced !(Maybe Int64) | MonitorOverflow
  deriving stock (Eq, Show)

data MonitorAdmissionError = OccurrenceUnavailable | MonitorAuthorityUnavailable | MonitorAuthorityWidened | MonitorHourlyBudget
  deriving stock (Eq, Show)

data FireRecord = FireRecord
  { monitor :: !MonitorId,
    conversation :: !Int64,
    task :: !(Maybe Int64),
    pending :: !Bool,
    cancelled :: !Bool,
    disposition :: !OccurrenceDisposition,
    coalesced :: !(Maybe Int64),
    snapshot :: !DefinitionSnapshot,
    revision :: !Int,
    scheduled :: !UTCTime,
    evidence :: !Text,
    payload :: !Value,
    counted :: !Bool
  }
  deriving stock (Show)

instance FromRow FireRecord where
  fromRow = do
    monitor <- field
    conversation <- field
    task <- field
    pending <- field
    cancelled <- field
    disposition <- enumField parseOccurrenceDisposition
    coalesced <- field
    snapshot <- jsonField
    revision <- field
    scheduled <- field
    evidence <- field
    payload <- jsonField
    counted <- field
    pure FireRecord {monitor, conversation, task, pending, cancelled, disposition, coalesced, snapshot, revision, scheduled, evidence, payload, counted}

admitMonitorTaskWithin :: (WithConnection :> es, IOE :> es) => MonitorFireId -> Maybe UTCTime -> Map Text Text -> Int64 -> Eff es (Either MonitorAdmissionError MonitorAdmission)
admitMonitorTaskWithin occurrence next grants seed = do
  (_ :: [Only Int64]) <- query "SELECT c.conversation_id FROM conversations c JOIN monitor_fires f USING(conversation_id) WHERE f.fire_id=? FOR UPDATE OF c" (Only occurrence)
  rows <-
    query
      "SELECT monitor_id,conversation_id,task_id,admission_state='pending',cancelled_at IS NOT NULL,disposition,coalesced_into,definition_snapshot::text,definition_revision,scheduled_at,trigger_evidence,COALESCE(trigger_payload,'null'::jsonb)::text,counted_at_admission\
      \ FROM monitor_fires WHERE fire_id=? FOR UPDATE"
      (Only occurrence)
  now <- databaseNow
  case rows :: [FireRecord] of
    [fire] | Just _ <- fire.task -> pure (Right MonitorAlreadyDispatched)
    [fire] | fire.pending && not fire.cancelled -> do
      definition <- loadDefinition fire.monitor
      case definition of
        Nothing -> pure (Left MonitorAuthorityUnavailable)
        Just current
          | fire.disposition == CoalescedOccurrence || fire.disposition == OverflowOccurrence -> do
              void $ execute "UPDATE monitor_fires SET admission_state='dispatched',dispatched_at=now(),finished_at=now() WHERE fire_id=?" (Only occurrence)
              when current.timed $ void $ execute "UPDATE monitors SET next_fire_at=?,updated_at=now() WHERE monitor_id=?" (next, current.monitorId)
              pure (Right (if fire.disposition == CoalescedOccurrence then MonitorCoalesced fire.coalesced else MonitorOverflow))
          | otherwise -> do
              let snapshot = fire.snapshot
              sources <- query "SELECT EXISTS(SELECT 1 FROM messages WHERE canonical_message_id=? AND conversation_id=? AND author_principal_id=?)" (seed, fire.conversation, current.owner)
              let liveAuthority = current.active && maybe True (> now) current.expires && sources == [Only True]
                  permittedGrants = Map.isSubmapOfBy (==) grants snapshot.grants && grants == taskGrants snapshot.profile grants
              case (current.owner, current.armingTurn) of
                (Just actor, Just _) | liveAuthority && permittedGrants -> do
                  recent <-
                    query
                      "SELECT count(*) FROM monitor_fires recent JOIN monitors m USING(monitor_id)\
                      \ WHERE recent.conversation_id=? AND m.continuation_kind='elaborated' AND NOT (m.trigger_kind='time_cron' AND m.schedule_cron IS NULL)\
                      \ AND recent.admission_state='dispatched' AND recent.disposition NOT IN ('coalesced','overflow') AND recent.dispatched_at>?"
                      (fire.conversation, addUTCTime (-3600) now)
                  let full = not (current.timed && not current.recurring) && any (\(Only count) -> (count :: Int64) >= 20) recent
                  if full
                    then pure (Left MonitorHourlyBudget)
                    else do
                      observations <- query "SELECT fire_id,trigger_evidence,COALESCE(trigger_payload,'null'::jsonb) FROM monitor_fires WHERE coalesced_into=? ORDER BY fire_id DESC LIMIT 80" (Only occurrence)
                      previous <-
                        query
                          "SELECT result->'observation' FROM monitor_fires WHERE monitor_id=? AND definition_revision=? AND fire_id<>? AND result->>'status'='succeeded' AND jsonb_typeof(result->'observation')='object' ORDER BY scheduled_at DESC,fire_id DESC LIMIT 1"
                          (fire.monitor, fire.revision, occurrence)
                      let baseline = listToMaybe [value | Only value <- previous :: [Only Value]]
                          evidence = [object ["fire" .= (identifier :: Int64), "evidence" .= T.take 5000 detail, "payload" .= (payload :: Value)] | (identifier, detail, payload) <- observations]
                          inputs =
                            object
                              [ "trigger" .= fire.evidence,
                                "payload" .= fire.payload,
                                "scheduled_at" .= fire.scheduled,
                                "definition_revision" .= fire.revision,
                                "change_only" .= snapshot.changeOnly,
                                "previous_observation" .= baseline,
                                "coalesced_evidence" .= (if null evidence then Nothing else Just evidence)
                              ]
                      identifier <- allocateJobId
                      groups <- query "SELECT legacy_group_id FROM conversations WHERE conversation_id=?" (Only fire.conversation)
                      let group = case groups of [Only value] -> GroupId value; _ -> error "monitor conversation disappeared"
                          contract = if snapshot.changeOnly then Just observationContract else Nothing
                          profile = (,) <$> snapshot.browserProfile <*> snapshot.browserVersion
                          spec = JobSpec group (PrincipalId actor) (CanonicalMessageId seed) snapshot.goal snapshot.profile grants inputs Nothing contract False (Just (JobMonitor fire.monitor occurrence)) profile (addUTCTime 3000 now)
                      void $
                        execute
                          "UPDATE monitor_fires SET admission_state='dispatched',dispatched_at=now(),task_id=?,disposition='task' WHERE fire_id=?"
                          (identifier, occurrence)
                      when current.timed $
                        void $
                          execute
                            "UPDATE monitors SET status=?,next_fire_at=?,fire_count=fire_count+?,updated_at=now() WHERE monitor_id=?"
                            (if isNothing next then ("fired" :: Text) else "armed", next, if fire.counted then (0 :: Int) else 1, current.monitorId)
                      pure (Right (MonitorTaskAdmitted identifier spec))
                _
                  | liveAuthority && not permittedGrants -> pure (Left MonitorAuthorityWidened)
                  | otherwise -> pure (Left MonitorAuthorityUnavailable)
    _ -> pure (Left OccurrenceUnavailable)

-- Change-only reminders explicitly ask for a business observation alongside the
-- user-facing summary. Ordinary jobs have no structured finishing protocol.
observationContract :: Contract
observationContract =
  either (error . T.unpack) id $
    parseContract $
      object
        [ "type" .= ("object" :: Text),
          "additionalProperties" .= False,
          "required" .= (["summary", "observation"] :: [Text]),
          "properties"
            .= object
              [ "summary" .= object ["type" .= ("string" :: Text)],
                "observation" .= object ["type" .= ("object" :: Text), "additionalProperties" .= True, "properties" .= object []]
              ]
        ]

monitorTaskProfile :: (WithConnection :> es, IOE :> es) => MonitorFireId -> Eff es TaskProfile
monitorTaskProfile fire = do
  rows <- query "SELECT COALESCE(definition_snapshot->>'profile',task_profile) FROM monitor_fires JOIN monitors USING(monitor_id) WHERE fire_id=?" (Only fire)
  pure $ case rows of [Only name] -> fromMaybe Basic (parseProfile name); _ -> Basic

-- Returns whether this result should be announced; no effect is replayed here.
recordMonitorResult :: (WithConnection :> es, IOE :> es) => MonitorFireId -> TaskStatus -> JobResult -> Eff es Bool
recordMonitorResult fire status result = withTransaction $ do
  (_ :: [Only Int64]) <- query "SELECT monitor_id FROM monitors JOIN monitor_fires USING(monitor_id) WHERE fire_id=? FOR UPDATE OF monitors" (Only fire)
  rows <- query "SELECT monitor_id,definition_revision,COALESCE((definition_snapshot->>'change_only')::boolean,false) FROM monitor_fires WHERE fire_id=?" (Only fire)
  case rows :: [(Int64, Int, Bool)] of
    [(monitor, revision, changeOnly)] -> do
      previous <- query "SELECT result FROM monitor_fires WHERE monitor_id=? AND definition_revision=? AND fire_id<>? AND result IS NOT NULL ORDER BY finished_at DESC,fire_id DESC LIMIT 1" (monitor, revision, fire)
      repeatedFailure <- query "SELECT EXISTS(SELECT 1 FROM monitor_fires WHERE monitor_id=? AND definition_revision=? AND fire_id<>? AND result->>'status'=? AND notified_at>now()-interval '1 hour')" (monitor, revision, fire, jsonStatus status)
      let observation :: Maybe Value
          observation = join (result.payload >>= parseMaybe (withObject "monitor result" (.:? "observation")))
          oldObservation = case previous of [Only value] -> join (parseMaybe (withObject "monitor result" (.:? "observation")) value); _ -> Nothing
          quiet = changeOnly && (if status == Succeeded then isJust observation && observation == oldObservation else repeatedFailure == [Only True])
          report = object ["status" .= status, "summary" .= result.text, "observation" .= observation]
      void $ execute "UPDATE monitor_fires SET result=?::jsonb,finished_at=now(),notified_at=CASE WHEN ? THEN NULL ELSE now() END WHERE fire_id=?" (jsonText report, quiet, fire)
      pure (not quiet)
    _ -> pure False
  where
    jsonStatus = \case Succeeded -> "succeeded" :: Text; Failed -> "failed"; BudgetExhausted -> "budget_exhausted"; Cancelled -> "cancelled"; _ -> "failed"

markMonitorJobStarted :: (WithConnection :> es, IOE :> es) => MonitorFireId -> Eff es ()
markMonitorJobStarted fire = void $ execute "UPDATE monitor_fires SET started_at=COALESCE(started_at,now()) WHERE fire_id=?" (Only fire)
