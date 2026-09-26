-- | Persistent identity and source provenance; execution lives in Max.Jobs.
module Max.DB.Job (allocateJobId, admitFromTurn, admitFromTurnWithAuthority) where

import Data.Int (Int64)
import Data.Text (Text)
import Database.PostgreSQL.Simple.Types (Only (..))
import Effectful
import Effectful.PostgreSQL (WithConnection, query)
import Max.DB.Authority (authorizeCallWithin)
import Max.DB.Transaction (withTransaction)
import Max.Execution.Authority (CallAuthority)
import Max.Execution.Types (ExecutionStep (..), StepReservation (..))
import Max.Jobs qualified as Jobs
import Max.Platform.Types (CanonicalMessageId (..), PrincipalId (..))
import Max.Task.Types (JobSpec (..), JobView)
import Max.Turn.Types (AgentTurnRef (..))
import OneBot.Types (GroupId (..))

-- The retained sequence prevents a stale task# from naming a new job after boot.
allocateJobId :: (WithConnection :> es, IOE :> es) => Eff es Int64
allocateJobId = do
  rows <- query "SELECT nextval('job_id_seq')" ()
  case rows of
    [Only identifier] -> pure identifier
    _ -> error "task identity sequence unavailable"

admitFromTurn :: (WithConnection :> es, IOE :> es) => Jobs.Jobs -> AgentTurnRef -> JobSpec -> Eff es (Either Text JobView)
admitFromTurn = admitFromTurnWithAuthority Nothing

admitFromTurnWithAuthority :: (WithConnection :> es, IOE :> es) => Maybe CallAuthority -> Jobs.Jobs -> AgentTurnRef -> JobSpec -> Eff es (Either Text JobView)
admitFromTurnWithAuthority authority jobs turn spec = do
  live <- liftIO (Jobs.authorizeJobStep jobs turn.atrTurnId (ExecutionWork CheckOnly))
  authorized <- withTransaction $ do
    caller <- authorizeCallWithin authority turn.atrTurnId spec.group spec.principal
    let GroupId groupId = spec.group
    source <- query "SELECT EXISTS(SELECT 1 FROM messages JOIN conversations USING(conversation_id) WHERE canonical_message_id=? AND author_principal_id=? AND legacy_group_id=?)" (spec.source.unCanonicalMessageId, spec.principal.unPrincipalId, groupId)
    pure (caller && source == [Only True])
  if live && authorized
    then do
      identifier <- allocateJobId
      liftIO (Jobs.admitJobWithAuthority authority jobs (Just turn.atrTurnId) identifier spec)
    else pure (Left "job caller or source is no longer authorized")
