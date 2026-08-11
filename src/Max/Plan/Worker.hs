-- | ADR 007 step 11: the thing that drives a suspended plan.
--
-- A plan parked at a fork is an armed suspension, not a queue entry: nothing
-- polls it, and nothing runs on a timer. It is woken by exactly two events, and
-- both of them are a row committing — a plan acquiring a checkpoint, and a
-- child turn reaching a terminal status. Postgres notifies on both, so the
-- worker's sleep has no deadline and its recheck-then-wait cannot miss a
-- commit. The lease exists only for the case a worker dies mid-drive.
--
-- The loop is the same shape "Max.Monitor" uses, for the same reasons. What is
-- different is that a plan's work is not one act but a small state machine, and
-- keeping that machine here rather than in the dispatcher is deliberate:
--
-- @
-- claim  -> decode the checkpoint against the head as it is NOW
--        -> ask Max.Plan.Drive what that means
--        -> dispatch / stop / resume / abandon
--        -> release, or clear
-- @
--
-- __Everything effectful is injected.__ Opening a turn for a subgoal, killing a
-- child, resuming a walk with real tools, and waking whoever owns the plan all
-- need the dispatch row — the whole of "Max.Handler"'s world — and none of them
-- need to be understood to understand this. The split also means the interesting
-- half is exercised without a bot: the decision is "Max.Plan.Drive" and is
-- pure, and this module is bookkeeping around it.
--
-- __A resumed walk that hits another fork parks again.__ It is not a special
-- case anywhere; it is the same suspension written by a different writer, and
-- the next claim dispatches its children. Sequential fan-out — /do these three,
-- then those two/ — therefore costs nothing to support.
module Max.Plan.Worker
  ( PlanDriver (..),
    Resumption (..),
    planWorker,
    drivePlan,
    claimLeaseSeconds,
  )
where

import Control.Monad (unless)
import Data.Aeson (Result (..), Value, fromJSON, object, (.=))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (addUTCTime, getCurrentTime)
import Effectful
import Effectful.Log (Log, logAttention, logInfo)
import Effectful.PostgreSQL (WithConnection)
import Max.DB.Notify (WorkChannel (..), claimOrWait)
import Max.DB.Plan
import Max.Plan.Drive
import Max.Plan.Execute (ExecState)
import Max.Plan.Reconcile (Desired, Running (..))
import Max.Turn.Types (AgentTurnId (..))
import Max.Util (catchSync)
import Control.Exception (SomeException)

-- | Long enough that a slow resume does not lose its plan, short enough that a
-- crashed process does not park one for a working day.
claimLeaseSeconds :: Int
claimLeaseSeconds = 120

claimBatchSize :: Int
claimBatchSize = 20

-- | What a resumed walk did.
data Resumption
  = -- | Reached its @done@. The rendered value, for whoever is told about it.
    Produced !Text
  | -- | Hit another fork. The node it stopped on and the state to park.
    Parked !Text !Value
  | -- | Stopped short. A hole, a failing tool, a spent budget — all the same
    -- shape to this module: the plan is over and somebody has to hear why.
    Stopped !Text
  deriving stock (Show, Eq)

-- | The effectful half, supplied by the host.
data PlanDriver es = PlanDriver
  { -- | Open a turn for one subgoal and record the spawn edge. 'Nothing' means
    -- it could not be started, which leaves the subgoal uncovered — the next
    -- wake tries again, because an unstarted child is indistinguishable from
    -- one that was never dispatched.
    pdSpawn :: WakeablePlan -> Desired -> Eff es (Maybe AgentTurnId),
    -- | Stop a child the plan no longer wants.
    pdStop :: WakeablePlan -> AgentTurnId -> Eff es (),
    -- | Continue the walk with real tools.
    pdResume :: WakeablePlan -> ExecState -> Eff es Resumption,
    -- | Tell whoever owns this plan how it came out.
    pdWake :: WakeablePlan -> Text -> Eff es ()
  }

planWorker ::
  (WithConnection :> es, Log :> es, IOE :> es) =>
  -- | Worker identity, for the lease.
  Text ->
  PlanDriver es ->
  Eff es ()
planWorker owner driver = loop
  where
    loop = do
      work <- claimOrWait PlanWork claim
      mapM_ run work
      loop

    claim = do
      now <- liftIO getCurrentTime
      claimWakeablePlans owner now (addUTCTime (fromIntegral claimLeaseSeconds) now) claimBatchSize

    run = \case
      Left err -> do
        -- A plan this binary cannot read. Left claimed until the lease lapses
        -- rather than closed: a newer binary may be about to take it, and
        -- abandoning somebody else's plan is worse than leaving it parked.
        logAttention "plan worker: suspended plan did not load" $
          object ["error" .= planLoadErrorText err]
      Right plan ->
        drivePlan owner driver plan
          `catchSync` \e -> do
            logAttention "plan worker: drive failed" $
              object
                [ "plan_id" .= plan.wpPlan.stRef.prPlanId.unPlanId,
                  "error" .= T.pack (show (e :: SomeException))
                ]
            -- Give the lease back rather than holding it for two minutes. The
            -- checkpoint is untouched, so the next attempt sees exactly what
            -- this one did.
            releasePlanClaim owner plan.wpPlan.stRef

-- | One plan, one decision, acted on.
--
-- Separated from the loop because everything interesting about a wake is here
-- and none of it needs a notification to reproduce.
drivePlan ::
  (WithConnection :> es, Log :> es, IOE :> es) =>
  Text ->
  PlanDriver es ->
  WakeablePlan ->
  Eff es ()
drivePlan owner driver plan = case fromJSON plan.wpCheckpoint.pkState of
  Error detail -> giveUp ("计划的执行状态读不回来了：" <> T.pack detail)
  Success (state :: ExecState) -> do
    settled <- listChildOutcomes ref
    running <- listRunningChildren ref
    let decision =
          driveFork
            plan.wpPlan.stDocument
            state
            [ SettledChild {scHash = child.coGoalHash, scValue = child.coResult, scChild = child.coChildTurn}
            | child <- settled
            ]
            [Running {rnHash = child.pcGoalHash, rnChild = child.pcChildTurn} | child <- running]
    -- Stops first, so a subgoal that is being both worked on and re-dispatched
    -- never has two children alive at once.
    mapM_ (driver.pdStop plan . (.rnChild)) decision.drStop
    case decision.drNext of
      WaitForChildren -> do
        spawned <- traverse (driver.pdSpawn plan) decision.drDispatch
        logInfo "plan: children dispatched" $
          object
            [ "plan_id" .= ref.prPlanId.unPlanId,
              "dispatched" .= length [() | Just _ <- spawned],
              "failed" .= length [() | Nothing <- spawned],
              "stopped" .= length decision.drStop
            ]
        -- Every subgoal that started is a running child, so this plan drops
        -- out of the wakeable set on its own; the claim is only in the way.
        releasePlanClaim owner ref
      Abandon reason -> giveUp reason
      Resume resumed -> do
        outcome <- driver.pdResume plan resumed
        case outcome of
          Produced value -> do
            finish PlanDone
            logInfo "plan: resumed to a result" $ object ["plan_id" .= ref.prPlanId.unPlanId]
            driver.pdWake plan value
          Stopped reason -> giveUp reason
          Parked node next -> do
            -- Another fork. Not a special case: the same suspension, written
            -- by a different writer, and the next claim dispatches it.
            parked <- suspendPlan ref plan.wpPlan.stRevision node next
            unless parked $
              logAttention "plan: re-park refused; plan moved during the resume" $
                object ["plan_id" .= ref.prPlanId.unPlanId]
            releasePlanClaim owner ref
  where
    ref = plan.wpPlan.stRef

    -- The checkpoint goes before the wake, and the wake before nothing: a
    -- process that dies in between loses the telling, not the plan's integrity.
    -- The other order would leave a plan that can be woken twice.
    giveUp reason = do
      finish PlanAbandoned
      logAttention "plan: abandoned" $
        object ["plan_id" .= ref.prPlanId.unPlanId, "reason" .= reason]
      driver.pdWake plan ("这个计划没能走完：" <> reason)

    finish status = do
      clearPlanCheckpoint ref
      closePlan ref status
