-- | The decision a woken driver makes, in the cases that are hard to reach
-- through a database and a scheduler.
--
-- The one this module exists for is the second dispatch: a reconciler that
-- knows only "desired" and "running" sees a finished child as neither, and
-- re-dispatches it — forever, since it finishes again each time. Everything
-- else here is a variation on the same question, which is what the third
-- column buys.
module Max.Plan.DriveSpec (spec) where

import Data.Aeson (Value (..))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Max.Plan.Drive
import Max.Plan.Execute (ExecState (..), initialState)
import Max.Plan.Reconcile (Desired (..), Running (..))
import Max.Plan.Schema (PlanSchema (..))
import Max.Plan.Types
import Test.Hspec

root :: Text
root = "turn:1:0"

goalNamed :: Text -> Goal
goalNamed objective =
  Goal
    { goalObjective = objective,
      goalExpected = SchemaText,
      goalAcceptance = [],
      goalBudget = emptyBudget,
      goalAuthority = Set.empty,
      goalResources = [],
      goalInputs = [],
      goalDeps = noDependencies,
      goalEvidence = [],
      goalAttempt = 0
    }

-- | A fork of the named subgoals, then a continuation that reads the first.
forkOf :: [(Text, Text)] -> PlanDocument
forkOf children =
  PlanDocument
    { pdRoot = root,
      pdPlan =
        Fork
          ForkNode
            { fnChildren = [(Binder binder, goalNamed objective) | (binder, objective) <- children],
              fnJoin = JoinAll,
              fnWatch = WatchOnFailure
            }
          (Done (EVar (Binder (case children of (binder, _) : _ -> binder; [] -> "a"))))
    }

-- | Parked on the fork, which for these plans is the root.
parked :: ExecState
parked = initialState

-- | Give every subgoal of the fork an @inputs@ block.
wanting :: [Text] -> PlanDocument -> PlanDocument
wanting names document = document {pdPlan = go document.pdPlan}
  where
    go = \case
      Fork fork continuation ->
        Fork
          fork {fnChildren = [(binder, goal {goalInputs = map Binder names}) | (binder, goal) <- fork.fnChildren]}
          continuation
      other -> other

settledWith :: Text -> Text -> Int -> SettledChild Int
settledWith objective answer child =
  SettledChild {scHash = goalHash (goalNamed objective), scValue = Just (String answer), scChild = child}

settledEmpty :: Text -> Int -> SettledChild Int
settledEmpty objective child =
  SettledChild {scHash = goalHash (goalNamed objective), scValue = Nothing, scChild = child}

runningOn :: Text -> Int -> Running Int
runningOn objective child = Running {rnHash = goalHash (goalNamed objective), rnChild = child}

spec :: Spec
spec = describe "driving a plan parked at a fork" $ do
  it "dispatches every subgoal when nothing has been started" $ do
    let outcome = driveFork (forkOf [("a", "查甲"), ("b", "查乙")]) parked [] ([] :: [Running Int])
    map (.dpDesired.dsBinder) outcome.drDispatch `shouldBe` [Binder "a", Binder "b"]
    map (.dpDesired.dsNode) outcome.drDispatch `shouldBe` [NodeId "turn:1:0/k0", NodeId "turn:1:0/k1"]
    outcome.drStop `shouldBe` []
    outcome.drNext `shouldBe` WaitForChildren

  it "does not dispatch a subgoal whose child has already finished" $ do
    -- The whole reason this module is not just 'reconcile'.  A finished child
    -- is neither desired-and-missing nor running, so a two-column diff would
    -- start it again — and it would finish again, forever.
    let outcome =
          driveFork
            (forkOf [("a", "查甲"), ("b", "查乙")])
            parked
            [settledWith "查甲" "甲的答案" 1]
            [runningOn "查乙" 2]
    outcome.drDispatch `shouldBe` []
    outcome.drStop `shouldBe` []
    outcome.drNext `shouldBe` WaitForChildren

  it "resumes past the fork with every child's result bound once they are all in" $ do
    let outcome =
          driveFork
            (forkOf [("a", "查甲"), ("b", "查乙")])
            parked
            [settledWith "查甲" "甲的答案" 1, settledWith "查乙" "乙的答案" 2]
            ([] :: [Running Int])
    outcome.drDispatch `shouldBe` []
    case outcome.drNext of
      Resume state -> do
        -- Past the fork: 'stepPlan' stops on a fork by construction, so moving
        -- the walk to the continuation is this module's job and nobody else's.
        state.esPath `shouldBe` PlanPath [StepContinue]
        state.esBindings
          `shouldBe` Map.fromList
            [(Binder "a", String "甲的答案"), (Binder "b", String "乙的答案")]
        -- Children cost turns, not calls.  A resumed walk still has its whole
        -- call budget, because it has not spent any of it.
        state.esCalls `shouldBe` 0
      other -> expectationFailure ("expected a resume, got " <> show other)

  it "keeps the bindings the walk already had" $ do
    let earlier = parked {esBindings = Map.fromList [(Binder "seed", String "早先")], esCalls = 2}
        outcome =
          driveFork (forkOf [("a", "查甲")]) earlier [settledWith "查甲" "甲的答案" 1] ([] :: [Running Int])
    case outcome.drNext of
      Resume state -> do
        Map.lookup (Binder "seed") state.esBindings `shouldBe` Just (String "早先")
        state.esCalls `shouldBe` 2
      other -> expectationFailure ("expected a resume, got " <> show other)

  it "stops when a child settled without a value, rather than retrying it" $ do
    -- The executor does not retry, and this does not either: the plan after
    -- the fork was validated believing that binder would be bound.
    let outcome =
          driveFork
            (forkOf [("a", "查甲"), ("b", "查乙")])
            parked
            [settledWith "查甲" "甲的答案" 1, settledEmpty "查乙" 2]
            ([] :: [Running Int])
    outcome.drDispatch `shouldBe` []
    case outcome.drNext of
      Abandon reason -> reason `shouldSatisfy` \r -> "b " `isPrefix` r
      other -> expectationFailure ("expected an abandon, got " <> show other)

  it "counts identical subgoals rather than collapsing them" $ do
    -- Asking two independent elaborations the same question and comparing them
    -- is a real technique.  One answer covers one of them.
    let outcome =
          driveFork
            (forkOf [("a", "查甲"), ("b", "查甲")])
            parked
            [settledWith "查甲" "甲的答案" 1]
            ([] :: [Running Int])
    map (.dpDesired.dsBinder) outcome.drDispatch `shouldBe` [Binder "b"]
    outcome.drNext `shouldBe` WaitForChildren

  it "binds both when two identical subgoals both came back" $ do
    let outcome =
          driveFork
            (forkOf [("a", "查甲"), ("b", "查甲")])
            parked
            [settledWith "查甲" "第一版" 1, settledWith "查甲" "第二版" 2]
            ([] :: [Running Int])
    case outcome.drNext of
      Resume state ->
        state.esBindings
          `shouldBe` Map.fromList [(Binder "a", String "第一版"), (Binder "b", String "第二版")]
      other -> expectationFailure ("expected a resume, got " <> show other)

  describe "what a child will be able to see" $ do
    it "resolves the names the subgoal asked for to their values" $ do
      -- ADR 002's isolation rule with actual values in it.  childEnv does the
      -- static half; this is the other one, computed here because here is where
      -- the parked bindings are.
      let held =
            parked
              { esBindings =
                  Map.fromList
                    [ (Binder "框架", String "effectful"),
                      (Binder "无关", String "别看")
                    ]
              }
          asking = wanting ["框架"] (forkOf [("a", "查甲")])
          outcome = driveFork asking held [] ([] :: [Running Int])
      map (.dpInputs) outcome.drDispatch `shouldBe` [[(Binder "框架", String "effectful")]]

    it "hands over nothing when the subgoal asked for nothing" $ do
      let held = parked {esBindings = Map.fromList [(Binder "无关", String "别看")]}
          outcome = driveFork (forkOf [("a", "查甲")]) held [] ([] :: [Running Int])
      map (.dpInputs) outcome.drDispatch `shouldBe` [[]]

    it "drops a name the parked state does not hold rather than faking one" $ do
      -- validatePlan rejects this as an unbound name, so it cannot arise for a
      -- plan that ran.  A child handed a fabricated value would be worse than
      -- one told it has nothing.
      let asking = wanting ["从未绑过"] (forkOf [("a", "查甲")])
          outcome = driveFork asking parked [] ([] :: [Running Int])
      map (.dpInputs) outcome.drDispatch `shouldBe` [[]]

  it "stops a child the edited plan no longer wants" $ do
    let outcome =
          driveFork (forkOf [("a", "查甲")]) parked [] [runningOn "查甲" 1, runningOn "查丙" 3]
    map (.rnChild) outcome.drStop `shouldBe` [3]
    outcome.drDispatch `shouldBe` []
    outcome.drNext `shouldBe` WaitForChildren

  it "stops a duplicate child working on a subgoal that already came back" $ do
    let outcome =
          driveFork (forkOf [("a", "查甲")]) parked [settledWith "查甲" "甲的答案" 1] [runningOn "查甲" 2]
    map (.rnChild) outcome.drStop `shouldBe` [2]
    -- Still resumes: the subgoal has its value, and the duplicate is waste
    -- rather than an obstacle.
    case outcome.drNext of
      Resume _ -> pure ()
      other -> expectationFailure ("expected a resume, got " <> show other)

  describe "a plan that moved under the checkpoint" $ do
    it "abandons and stops everything when the fork is gone" $ do
      -- The ordinary cause is a steer.  Reported rather than reinterpreted, in
      -- exactly the way stepPlan reports PathNotInPlan.
      let rewritten = PlanDocument {pdRoot = root, pdPlan = Done (ELit (LitText "算了"))}
          outcome = driveFork rewritten parked [] [runningOn "查甲" 1]
      map (.rnChild) outcome.drStop `shouldBe` [1]
      case outcome.drNext of
        Abandon reason -> reason `shouldSatisfy` \r -> "计划改了" `isPrefix` r
        other -> expectationFailure ("expected an abandon, got " <> show other)

    it "abandons when the path names no node at all" $ do
      let outcome =
            driveFork (forkOf [("a", "查甲")]) parked {esPath = PlanPath [StepThen]} [] ([] :: [Running Int])
      case outcome.drNext of
        Abandon reason -> reason `shouldSatisfy` \r -> "不存在" `isInfix` r
        other -> expectationFailure ("expected an abandon, got " <> show other)

isPrefix :: Text -> Text -> Bool
isPrefix = T.isPrefixOf

isInfix :: Text -> Text -> Bool
isInfix = T.isInfixOf
