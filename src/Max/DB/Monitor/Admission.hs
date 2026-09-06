-- | Atomic occurrence -> task admission, including frozen authority and
-- durable clock advancement. No workflow decisions are delegated to SQL.
module Max.DB.Monitor.Admission (MonitorAdmission (..), MonitorAdmissionError (..), admitMonitorTaskWithin) where

import Control.Monad (void, when)
import Data.Aeson (Value, object, (.=))
import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (isNothing)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime, addUTCTime)
import Database.PostgreSQL.Simple.FromRow (FromRow (..), field)
import Database.PostgreSQL.Simple.Types (Only (..))
import Effectful
import Effectful.PostgreSQL (WithConnection, execute, query)
import Max.DB.Codec (enumField, jsonField)
import Max.DB.Monitor.Occurrence
import Max.DB.Task.Record (databaseNow, jsonText)
import Max.Monitor.Policy
import Max.Monitor.Types (MonitorFireId (..), MonitorId)
import Max.Task.Types (profileName, taskGrants)

data MonitorAdmission = MonitorTaskAdmitted !Int64 | MonitorCoalesced !(Maybe Int64) | MonitorOverflow
  deriving stock (Eq, Show)

data MonitorAdmissionError = OccurrenceClaimLost | MonitorAuthorityUnavailable | MonitorAuthorityWidened | MonitorHourlyBudget | InvalidDefinitionSnapshot
  deriving stock (Eq, Show)

data FireRecord = FireRecord
  { monitor :: !MonitorId,
    conversation :: !Int64,
    task :: !(Maybe Int64),
    pending :: !Bool,
    cancelled :: !Bool,
    claimOwner :: !(Maybe Text),
    lease :: !(Maybe UTCTime),
    disposition :: !OccurrenceDisposition,
    coalesced :: !(Maybe Int64),
    rawSnapshot :: !Value,
    revision :: !Int,
    scheduled :: !UTCTime,
    evidence :: !Text,
    counted :: !Bool
  }
  deriving stock (Show)

instance FromRow FireRecord where
  fromRow =
    FireRecord
      <$> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> enumField parseOccurrenceDisposition
      <*> field
      <*> jsonField
      <*> field
      <*> field
      <*> field
      <*> field

admitMonitorTaskWithin :: (WithConnection :> es, IOE :> es) => Text -> MonitorFireId -> Maybe UTCTime -> Map Text Text -> Int64 -> Eff es (Either MonitorAdmissionError MonitorAdmission)
admitMonitorTaskWithin owner occurrence next grants seed = do
  (_ :: [Only Int64]) <- query "SELECT c.conversation_id FROM conversations c JOIN monitor_fires f USING(conversation_id) WHERE f.fire_id=? FOR UPDATE OF c" (Only occurrence)
  rows <-
    query
      "SELECT monitor_id,conversation_id,task_id,admission_state='pending',cancelled_at IS NOT NULL,claim_owner,claim_expires_at,disposition,coalesced_into,definition_snapshot::text,definition_revision,scheduled_at,trigger_evidence,counted_at_admission\
      \ FROM monitor_fires WHERE fire_id=? FOR UPDATE"
      (Only occurrence)
  now <- databaseNow
  case rows :: [FireRecord] of
    [fire] | Just identifier <- fire.task -> pure (Right (MonitorTaskAdmitted identifier))
    [fire] | fire.pending && not fire.cancelled && fire.claimOwner == Just owner && maybe False (> now) fire.lease -> do
      definition <- loadDefinition fire.monitor
      case definition of
        Nothing -> pure (Left MonitorAuthorityUnavailable)
        Just current -> case restoreSnapshot current.snapshot fire.rawSnapshot of
          Nothing -> pure (Left InvalidDefinitionSnapshot)
          Just snapshot
            | fire.disposition == CoalescedOccurrence || fire.disposition == OverflowOccurrence -> do
                void $ execute "UPDATE monitor_fires SET admission_state='dispatched',dispatched_at=now(),claim_owner=NULL,claim_expires_at=NULL WHERE fire_id=?" (Only occurrence)
                when current.timed $ void $ execute "UPDATE monitors SET next_fire_at=?,updated_at=now() WHERE monitor_id=?" (next, current.monitorId)
                pure (Right (if fire.disposition == CoalescedOccurrence then MonitorCoalesced fire.coalesced else MonitorOverflow))
            | otherwise -> do
                sources <- query "SELECT EXISTS(SELECT 1 FROM messages WHERE canonical_message_id=? AND conversation_id=? AND author_principal_id=?)" (seed, fire.conversation, current.owner)
                let liveAuthority = current.active && maybe True (> now) current.expires && sources == [Only True]
                    permittedGrants = Map.isSubmapOfBy (==) grants snapshot.grants && grants == taskGrants snapshot.profile grants
                case (current.owner, current.armingTurn) of
                  (Just actor, Just sourceTurn) | liveAuthority && permittedGrants -> do
                    recent <-
                      query
                        "SELECT count(*) FROM monitor_fires recent JOIN monitors m USING(monitor_id)\
                        \ WHERE recent.conversation_id=? AND m.continuation_kind='elaborated' AND NOT (m.trigger_kind='time_cron' AND m.schedule_cron IS NULL)\
                        \ AND recent.admission_state='dispatched' AND recent.disposition NOT IN ('coalesced','overflow') AND recent.dispatched_at>?"
                        (fire.conversation, addUTCTime (-3600) now)
                    let full = not (current.timed && not current.recurring) && any (\(Only count) -> (count :: Int64) >= 20) recent
                    if full
                      then do
                        void $ execute "UPDATE monitor_fires SET claim_owner=NULL,claim_expires_at=NULL WHERE fire_id=?" (Only occurrence)
                        pure (Left MonitorHourlyBudget)
                      else do
                        observations <- query "SELECT fire_id,trigger_evidence FROM monitor_fires WHERE coalesced_into=? ORDER BY fire_id DESC LIMIT 80" (Only occurrence)
                        let evidence = [object ["fire" .= (identifier :: Int64), "evidence" .= T.take 5000 detail] | (identifier, detail) <- observations]
                            inputs =
                              object
                                [ "trigger" .= fire.evidence,
                                  "scheduled_at" .= fire.scheduled,
                                  "definition_revision" .= fire.revision,
                                  "coalesced_evidence" .= (if null evidence then Nothing else Just evidence)
                                ]
                        tasks <-
                          query
                            "INSERT INTO durable_tasks(conversation_id,owner_principal_id,source_turn_id,source_message_id,admission_key,monitor_fire_id,objective,profile,inputs,grants,max_calls,max_rounds,deadline,created_at)\
                            \ VALUES(?,?,?,?,?,?,?,?,?::jsonb,?::jsonb,?,?,?,?) RETURNING task_id"
                            ( fire.conversation,
                              actor,
                              sourceTurn,
                              seed,
                              "monitor-fire:" <> T.pack (show occurrence.unMonitorFireId),
                              occurrence,
                              snapshot.goal,
                              profileName snapshot.profile,
                              jsonText inputs,
                              jsonText grants,
                              200 :: Int,
                              400 :: Int,
                              addUTCTime 3000 now,
                              now
                            )
                        case tasks of
                          [Only identifier] -> do
                            void $ execute "INSERT INTO task_revisions(task_id,revision,objective,author_principal_id) VALUES(?,1,?,?)" (identifier, snapshot.goal, actor)
                            void $
                              execute
                                "UPDATE monitor_fires SET admission_state='dispatched',dispatched_at=now(),task_id=?,disposition='task',claim_owner=NULL,claim_expires_at=NULL,next_attempt_at=NULL,last_error=NULL,parked_at=NULL WHERE fire_id=?"
                                (identifier, occurrence)
                            when current.timed $
                              void $
                                execute
                                  "UPDATE monitors SET status=?,next_fire_at=?,fire_count=fire_count+?,updated_at=now() WHERE monitor_id=?"
                                  (if isNothing next then ("fired" :: Text) else "armed", next, if fire.counted then (0 :: Int) else 1, current.monitorId)
                            pure (Right (MonitorTaskAdmitted identifier))
                          _ -> error "monitor admission did not create a task"
                  _
                    | liveAuthority && not permittedGrants -> pure (Left MonitorAuthorityWidened)
                    | otherwise -> pure (Left MonitorAuthorityUnavailable)
    _ -> pure (Left OccurrenceClaimLost)
