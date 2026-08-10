module Max.Plan.ReconcileSpec (spec) where

import Data.Set qualified as Set
import Data.Text (Text)
import Max.Plan.Reconcile
import Max.Plan.Schema (PlanSchema (..))
import Max.Plan.Types
import Test.Hspec

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

forkOf :: [(Text, Text)] -> Plan -> Plan
forkOf children =
  Fork
    ForkNode
      { fnChildren = [(Binder name, goalNamed objective) | (name, objective) <- children],
        fnJoin = JoinAll,
        fnWatch = WatchOnFailure
      }

-- A child as the storage layer reports it: the goal it serves, named by
-- whatever the caller uses to address one.
child :: Text -> Int -> Running Int
child objective identity = Running {rnHash = goalHash (goalNamed objective), rnChild = identity}

spec :: Spec
spec = do
  describe "the desired set" $ do
    it "is the fork children, and never the holes" $ do
      -- A hole is the front model's own next step, elaborated in place with
      -- everything it can see.  Dispatching one to a child that sees only the
      -- goal would be a different, worse thing than what the plan asked for.
      let plan =
            forkOf [("a", "查甲"), ("b", "查乙")] $
              Guard (PBool True) (Done (EVar (Binder "a"))) (Hole (goalNamed "想想别的"))
      map (.dsBinder) (desiredChildren "turn:1:0" plan) `shouldBe` [Binder "a", Binder "b"]

    it "names each subgoal by its position and its content" $ do
      let plan = forkOf [("a", "查甲")] (Done (EVar (Binder "a")))
      map (\item -> (item.dsNode.unNodeId, item.dsHash)) (desiredChildren "turn:1:0" plan)
        `shouldBe` [("turn:1:0/k0", goalHash (goalNamed "查甲"))]

    it "is empty for a plan with no forks" $
      desiredChildren "turn:1:0" (Done (ELit (LitText "ok"))) `shouldBe` []

  describe "reconciliation" $ do
    let twoGoals = desiredChildren "turn:1:0" (forkOf [("a", "查甲"), ("b", "查乙")] (Done (EVar (Binder "a"))))

    it "dispatches everything when nothing is running yet" $ do
      let outcome = reconcile twoGoals ([] :: [Running Int])
      map (.dsBinder) outcome.rcDispatch `shouldBe` [Binder "a", Binder "b"]
      outcome.rcStop `shouldBe` []
      outcome.rcKeep `shouldBe` []

    it "leaves running work alone when the plan still wants it" $ do
      let outcome = reconcile twoGoals [child "查甲" 1, child "查乙" 2]
      outcome.rcDispatch `shouldBe` []
      outcome.rcStop `shouldBe` []
      map (.rnChild) outcome.rcKeep `shouldBe` [1, 2]

    it "dispatches only the half nobody is working on" $ do
      let outcome = reconcile twoGoals [child "查甲" 1]
      map (.dsBinder) outcome.rcDispatch `shouldBe` [Binder "b"]
      map (.rnChild) outcome.rcKeep `shouldBe` [1]

    it "stops a child the plan no longer asks for" $ do
      let outcome = reconcile twoGoals [child "查甲" 1, child "查丙" 3]
      map (.dsBinder) outcome.rcDispatch `shouldBe` [Binder "b"]
      map (.rnChild) outcome.rcStop `shouldBe` [3]
      map (.rnChild) outcome.rcKeep `shouldBe` [1]

    it "stops everything when the plan stops wanting any of it" $ do
      let outcome = reconcile [] [child "查甲" 1, child "查乙" 2]
      outcome.rcDispatch `shouldBe` []
      map (.rnChild) outcome.rcStop `shouldBe` [1, 2]

  describe "a goal that only moved" $
    it "is not a change, so the child already running it is untouched" $ do
      -- "Do that, then also X": the old root becomes a subgoal of a new one.
      -- Its bytes never changed, so the work under way must not be disturbed —
      -- this is the property the whole steering design rests on.
      let before' = desiredChildren "turn:1:0" (forkOf [("a", "查甲")] (Done (EVar (Binder "a"))))
          after' =
            desiredChildren "turn:1:0" $
              forkOf [("first", "先做点别的"), ("a", "查甲")] (Done (EVar (Binder "a")))
          runningChild = child "查甲" 1
      -- The node id moved from k0 to k1 …
      map (.dsNode) before' `shouldNotBe` map (.dsNode) (filter ((== Binder "a") . (.dsBinder)) after')
      -- … and the reconciler does not care.
      let outcome = reconcile after' [runningChild]
      map (.dsBinder) outcome.rcDispatch `shouldBe` [Binder "first"]
      outcome.rcStop `shouldBe` []
      map (.rnChild) outcome.rcKeep `shouldBe` [1]

  describe "identical subgoals" $ do
    -- Asking two independent elaborations the same question and comparing the
    -- answers is a real technique, so identical goals are counted rather than
    -- collapsed.  A set difference would look at one running child, decide the
    -- pair was covered, and quietly run half the work.
    let twice = desiredChildren "turn:1:0" (forkOf [("a", "翻译"), ("b", "翻译")] (Done (EVar (Binder "a"))))

    it "dispatches the second copy when only one is running" $ do
      let outcome = reconcile twice [child "翻译" 1]
      map (.dsBinder) outcome.rcDispatch `shouldBe` [Binder "b"]
      map (.rnChild) outcome.rcKeep `shouldBe` [1]

    it "keeps both when both are running" $ do
      let outcome = reconcile twice [child "翻译" 1, child "翻译" 2]
      outcome.rcDispatch `shouldBe` []
      outcome.rcStop `shouldBe` []
      map (.rnChild) outcome.rcKeep `shouldBe` [1, 2]

    it "stops the surplus when more are running than are wanted" $ do
      let once = desiredChildren "turn:1:0" (forkOf [("a", "翻译")] (Done (EVar (Binder "a"))))
          outcome = reconcile once [child "翻译" 1, child "翻译" 2]
      outcome.rcDispatch `shouldBe` []
      map (.rnChild) outcome.rcStop `shouldBe` [2]
      map (.rnChild) outcome.rcKeep `shouldBe` [1]

  describe "stability" $
    it "is a no-op the second time, over an unchanged plan" $ do
      -- Reconciling is not a one-shot: it runs on every edit and every
      -- completion.  One that churned would restart work on every message the
      -- group sent.
      let plan = forkOf [("a", "查甲"), ("b", "查甲")] (Done (EVar (Binder "a")))
          desired = desiredChildren "turn:1:0" plan
          running = [child "查甲" 1, child "查甲" 2]
          once = reconcile desired running
          again = reconcile desired (once.rcKeep <> map dispatched once.rcDispatch)
      once.rcDispatch `shouldBe` []
      again.rcDispatch `shouldBe` []
      again.rcStop `shouldBe` []
      map (.rnChild) again.rcKeep `shouldBe` [1, 2]
  where
    dispatched item = Running {rnHash = item.dsHash, rnChild = 0}
