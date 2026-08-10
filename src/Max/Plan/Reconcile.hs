-- | ADR 007 step 4: what to start and what to stop, when a plan has changed
-- under running children.
--
-- The design's central bet is that this decision is arithmetic rather than
-- judgement. A model that has just rewritten a plan is not asked which of its
-- children survive; the two sides are compared by content and the difference
-- is the answer:
--
-- @
-- open subgoals of the plan head  = desired
-- children still running          = actual
--   in desired, not actual → dispatch
--   in actual, not desired → stop
--   in both                → leave alone
-- @
--
-- Desired-versus-actual, the shape a React diff or a Kubernetes reconciler
-- has. What makes it cheap here is that a 'Goal' is a self-contained value, so
-- "the same work" is a comparison of hashes and not of graph positions — see
-- ADR 007, "Unify the history; keep the plan a value".
--
-- Two consequences worth stating, because both are load-bearing:
--
--   * __Only fork children are dispatched.__  A 'Max.Plan.Types.Hole' is the
--     front model's own next step, elaborated in place with everything it can
--     see; a fork child is delegated to an elaboration that sees only its
--     'Goal'. 'Max.Plan.Types.planChildren' is therefore the desired set and
--     'Max.Plan.Types.planHoles' is not.
--   * __Matching is by multiset, not by set.__  Two byte-identical subgoals in
--     one fork are legitimate — asking two independent elaborations the same
--     question and comparing them is a real technique — so identical goals are
--     counted rather than collapsed. A set difference would look at one
--     running child, decide the pair was covered, and quietly run half the
--     work.
--
-- A goal that moved position in an edited plan is /not/ a change: the node id
-- a child was dispatched under is journal provenance, and re-parenting a goal
-- under a larger one leaves its bytes alone. That is what makes "do that, then
-- also X" free — the subtree already running is undisturbed.
module Max.Plan.Reconcile
  ( Desired (..),
    Running (..),
    Reconciliation (..),
    desiredChildren,
    reconcile,
  )
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Max.Plan.Types (Binder, Goal, NodeId, Plan, goalHash, planChildren)

-- | A subgoal the current plan wants worked on, with the identity it is
-- matched by.
data Desired = Desired
  { dsNode :: !NodeId,
    dsBinder :: !Binder,
    dsGoal :: !Goal,
    dsHash :: !Text
  }
  deriving stock (Show, Eq)

-- | A child that has not finished. Parameterized over whatever the caller uses
-- to name one — a turn id, an edge row — so this module stays free of storage
-- types and stays testable without a database.
data Running a = Running
  { rnHash :: !Text,
    rnChild :: !a
  }
  deriving stock (Show, Eq)

data Reconciliation a = Reconciliation
  { -- | Subgoals with nobody working on them, in plan order.
    rcDispatch :: ![Desired],
    -- | Children whose work the plan no longer wants.
    rcStop :: ![Running a],
    -- | Children whose goal survived the edit untouched. Named rather than
    -- implied: leaving work alone is the outcome an edit should usually have,
    -- and a caller should be able to report it.
    rcKeep :: ![Running a]
  }
  deriving stock (Show, Eq)

-- | The desired set: every subgoal of every fork in this plan.
desiredChildren :: Text -> Plan -> [Desired]
desiredChildren root plan =
  [ Desired {dsNode = node, dsBinder = binder, dsGoal = goal, dsHash = goalHash goal}
    | (node, binder, goal) <- planChildren root plan
  ]

-- | Diff the two sides.
--
-- Children are considered in the order given and subgoals in plan order, so
-- the answer is deterministic when several share a hash. Which of two
-- identical children is kept does not matter — they are the same request — but
-- /that the same one is kept every time/ does, or a reconcile run twice over
-- an unchanged plan would churn.
reconcile :: [Desired] -> [Running a] -> Reconciliation a
reconcile desired running =
  Reconciliation
    { rcDispatch = uncovered covered desired,
      rcStop = reverse stopped,
      rcKeep = reverse kept
    }
  where
    wanted :: Map Text Int
    wanted = Map.fromListWith (+) [(item.dsHash, 1) | item <- desired]

    (_, kept, stopped) = foldl step (wanted, [], []) running

    step (remaining, keeps, stops) child =
      case Map.lookup child.rnHash remaining of
        Just n
          | n > 0 -> (Map.insert child.rnHash (n - 1) remaining, child : keeps, stops)
        _ -> (remaining, keeps, child : stops)

    covered :: Map Text Int
    covered = Map.fromListWith (+) [(child.rnHash, 1) | child <- kept]

    -- Walk the subgoals in plan order, skipping as many of each hash as are
    -- already being worked on.
    uncovered _ [] = []
    uncovered skip (item : rest) = case Map.lookup item.dsHash skip of
      Just n | n > 0 -> uncovered (Map.insert item.dsHash (n - 1) skip) rest
      _ -> item : uncovered skip rest
