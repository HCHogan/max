-- | ADR 007 step 11: what to do next with a plan that is parked at a fork.
--
-- "Max.Plan.Reconcile" answers /which children should be running/. This
-- answers the larger question a woken driver actually has, which the
-- reconciler alone cannot: children that have already finished are neither
-- desired-and-missing nor running, and a diff that only knows those two
-- categories would dispatch every completed child a second time, forever.
--
-- So this is the reconciler with a third column — settled — and the ordering
-- is the whole content:
--
-- @
-- for each subgoal of the parked fork, in plan order:
--   a settled child with this goal's hash?  -> its value binds, or it failed
--   otherwise                               -> reconcile against what is running
-- @
--
-- Three properties are load-bearing.
--
--   * __Only the parked fork's children are desired.__  'Max.Plan.Types.planChildren'
--     walks the whole plan, which is right for a projection and wrong for a
--     dispatch: a later fork's subgoals read bindings that do not exist yet.
--     The desired set is taken by descending the checkpoint's own path, so it
--     is exactly the fork the walk stopped on.
--   * __Matching is by multiset, in plan order.__  Two byte-identical subgoals
--     in one fork are legitimate, so results are consumed from a pool keyed by
--     hash rather than looked up in a map. Which of two identical results binds
--     to which of two identical binders does not matter — they are answers to
--     the same question — but that the pairing is deterministic does.
--   * __A settled child with no value is a stop, not a retry.__  The executor
--     does not retry and neither does this: a child that crashed, was killed,
--     or declined to answer leaves a binder that cannot be bound, and the plan
--     after that point was validated believing it would be.
--
-- Everything here is pure, so the interesting cases — a steer that deleted the
-- fork, a child that failed, a duplicate dispatch — are unit tests rather than
-- a database and a scheduler.
module Max.Plan.Drive
  ( SettledChild (..),
    Drive (..),
    DriveNext (..),
    driveFork,
  )
where

import Data.Aeson (Value)
import Data.List (foldl')
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Max.Plan.Execute (ExecState (..), subplanAt)
import Max.Plan.Reconcile (Desired (..), Reconciliation (..), Running (..), reconcile)
import Max.Plan.Types

-- | A child that is decided, in the order its spawn edge was written.
--
-- The value is 'Nothing' for every way of finishing that is not an answer —
-- crashed, aborted, silent. They are one fact here on purpose: what the plan
-- can do about them is identical, and the difference is the failure text's
-- business.
data SettledChild a = SettledChild
  { scHash :: !Text,
    scValue :: !(Maybe Value),
    scChild :: !a
  }
  deriving stock (Show, Eq)

-- | What the driver should do, in the order it should do it.
data Drive a = Drive
  { -- | Subgoals with nobody working on them.
    drDispatch :: ![Desired],
    -- | Children the plan no longer wants. A steer produced these, or a
    -- duplicate dispatch did.
    drStop :: ![Running a],
    drNext :: !DriveNext
  }
  deriving stock (Show, Eq)

data DriveNext
  = -- | Some subgoal has a child working on it. Nothing more to decide until
    -- one settles.
    WaitForChildren
  | -- | Every subgoal of the fork has a value. Continue the walk from here:
    -- the fork's continuation, with each child's result bound to its binder.
    Resume !ExecState
  | -- | The walk cannot continue, and why. Distinct from waiting: nobody is
    -- coming, and whoever owns the plan needs to hear it.
    Abandon !Text
  deriving stock (Show, Eq)

-- | Decide, given the plan as it is now and everything known about its
-- children.
--
-- The checkpoint's path is authoritative about /which/ fork this is, and the
-- plan is authoritative about what that fork wants. When the two disagree — a
-- steer rewrote the plan while a child was running, and the node the state
-- stood on is gone — that is reported rather than reinterpreted, exactly as
-- 'Max.Plan.Execute.stepPlan' reports 'Max.Plan.Execute.PathNotInPlan'.
driveFork ::
  -- | The plan head as it is now, and the root its node ids hang under.
  PlanDocument ->
  -- | Where the walk parked.
  ExecState ->
  [SettledChild a] ->
  [Running a] ->
  Drive a
driveFork document state settled running =
  case subplanAt document.pdPlan state.esPath of
    Just (Fork fork _) -> atFork fork
    -- Either a steer deleted the fork or the checkpoint belongs to another
    -- plan.  Stopping the children is right in both cases: whatever they are
    -- working on, this plan no longer says so.
    Just _ -> abandonAll ("计划改了，" <> here <> " 已经不是当初那个 fork")
    Nothing -> abandonAll ("计划改了，" <> here <> " 在现在的计划里不存在")
  where
    here = (nodeIdIn document.pdRoot state.esPath).unNodeId

    abandonAll reason = Drive {drDispatch = [], drStop = running, drNext = Abandon reason}

    atFork fork =
      let desired =
            [ Desired
                { dsNode = nodeIdIn document.pdRoot (child (state.esPath) index),
                  dsBinder = binder,
                  dsGoal = goal,
                  dsHash = goalHash goal
                }
            | (index, (binder, goal)) <- zip [0 ..] fork.fnChildren
            ]
          (bound, failures, uncovered) = consume desired
       in case failures of
            -- Report one, not all: the first failure is what the plan actually
            -- stopped on, and a list of them reads as though several things
            -- went wrong independently when the second child was only ever
            -- going to be discarded.
            (binder, reason) : _ ->
              Drive
                { drDispatch = [],
                  drStop = running,
                  drNext = Abandon (binder.unBinder <> " 这个子任务" <> reason)
                }
            [] ->
              let outcome = reconcile uncovered running
               in Drive
                    { drDispatch = outcome.rcDispatch,
                      drStop = outcome.rcStop,
                      drNext =
                        if null uncovered
                          then Resume (resumed bound)
                          else WaitForChildren
                    }

    child path index = PlanPath (path.unPlanPath <> [StepChild index])

    -- Past the fork, with every child's result in scope.  The fork node itself
    -- is never stepped through: 'stepPlan' stops on it by construction, so the
    -- driver is what moves the walk to the continuation.
    resumed bound =
      state
        { esPath = PlanPath (state.esPath.unPlanPath <> [StepContinue]),
          esBindings = foldl' (\into' (binder, value) -> Map.insert binder value into') state.esBindings bound
        }

    -- Walk the subgoals in plan order, taking from the pool of settled children
    -- that share each one's hash.  A subgoal whose pool is empty is uncovered
    -- and goes to the reconciler; one that draws a valueless child is a stop.
    consume desired = go (pool settled) desired
      where
        go _ [] = ([], [], [])
        go remaining (item : rest) = case Map.lookup item.dsHash remaining of
          Just (candidate : more) ->
            let (bound, failures, uncovered) = go (Map.insert item.dsHash more remaining) rest
             in case candidate.scValue of
                  Just value -> ((item.dsBinder, value) : bound, failures, uncovered)
                  Nothing -> (bound, (item.dsBinder, "没有交回结果") : failures, uncovered)
          _ ->
            let (bound, failures, uncovered) = go remaining rest
             in (bound, failures, item : uncovered)

    pool :: [SettledChild a] -> Map Text [SettledChild a]
    pool = Map.fromListWith (flip (<>)) . map (\item -> (item.scHash, [item]))
