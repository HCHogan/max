module Max.DB.PlanSpec (spec) where

import Control.Concurrent.Async (mapConcurrently)
import Data.Aeson (Value (..), object, (.=))
import Data.Either (rights)
import Data.Int (Int64)
import Data.List (sort)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime, addUTCTime)
import Control.Exception (try)
import Database.PostgreSQL.Simple (Only (..), SqlError, execute, query)
import Helpers (insertRawMessage, testTime, truncateAll, withDb)
import Max.DB.AgentTurn (AgentTurnTerminal (..), finishAgentTurn, markAgentTurnRunning, startAgentTurn)
import Max.DB.Connection (DbPool, withConn)
import Max.DB.Plan
import Max.Effects.Tools (SchemaVersion (..), ToolRef (..))
import Max.Plan.Reconcile
import Max.Plan.Schema (PlanSchema (..))
import Max.Plan.Types
import Max.Platform.Types (CanonicalMessageId (..), PrincipalId (..))
import Max.Turn.Types (AgentTurnRef (..))
import OneBot.Types (GroupId (..))
import Test.Hspec

data Fixture = Fixture
  { fxGroup :: !GroupId,
    fxPrincipal :: !PrincipalId,
    fxTurn :: !AgentTurnRef
  }

-- A plan with a call and a hole, so a revision carries something with real
-- structure rather than a placeholder that would hide an encoding bug.
document :: Text -> PlanDocument
document objective =
  PlanDocument
    { pdRoot = "turn:1:0",
      pdPlan =
        Call
          CallNode
            { cnBind = Binder "hits",
              cnTool = ToolRef "search_web",
              cnSchemaVersion = SchemaVersion 3,
              cnInput = EObject [("query", ELit (LitText objective))]
            }
          (Hole (goalNamed objective))
    }

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

spec :: DbPool -> Spec
spec pool = before_ (truncateAll pool) $ describe "Max.DB.Plan" $ do
  it "opens a plan and reads its first revision back unchanged" $ do
    fixture <- createFixture pool 42 1001
    ref <- withDb pool (openPlan fixture.fxTurn (document "查一下"))
    ref.prOrdinal `shouldBe` PlanOrdinal 1
    head' <- withDb pool (loadPlanHead ref) >>= requireHead
    head'.stRevision `shouldBe` Revision 1
    head'.stStatus `shouldBe` PlanOpen
    head'.stRootTurn `shouldBe` fixture.fxTurn.atrTurnId
    head'.stDocument `shouldBe` document "查一下"

  it "serializes concurrent opens into a stable conversation ordinal" $ do
    fixture <- createFixture pool 42 1001
    refs <-
      mapConcurrently
        (\n -> withDb pool (openPlan fixture.fxTurn (document (tshow n))))
        [1 .. 8 :: Int]
    sort (map (.prOrdinal) refs) `shouldBe` map PlanOrdinal [1 .. 8]

  it "takes the conversation from the turn, so the two cannot disagree" $ do
    here <- createFixture pool 42 1001
    elsewhere <- createFixture pool 43 1002
    _ <- withDb pool (openPlan here.fxTurn (document "这边"))
    _ <- withDb pool (openPlan elsewhere.fxTurn (document "那边"))
    scoped <- withConn pool $ \connection ->
      query
        connection
        "SELECT count(*) FROM plans p JOIN agent_turns t ON t.turn_id = p.root_turn_id \
        \ WHERE p.conversation_id <> t.conversation_id"
        ()
    (scoped :: [Only Int64]) `shouldBe` [Only 0]

  describe "revision" $ do
    it "moves the head and returns the token the next write needs" $ do
      fixture <- createFixture pool 42 1001
      ref <- withDb pool (openPlan fixture.fxTurn (document "一"))
      next <-
        withDb pool $
          revisePlan ref (Revision 1) CauseSteer (Just fixture.fxPrincipal) (Just fixture.fxTurn) (document "二")
      next `shouldBe` Right (Revision 2)
      head' <- withDb pool (loadPlanHead ref) >>= requireHead
      head'.stRevision `shouldBe` Revision 2
      head'.stDocument `shouldBe` document "二"

    it "refuses a write based on a revision that has moved, and says where it is" $ do
      -- The whole reason the head is a CAS token.  Two writers read revision 1
      -- — a child reporting a result and a human steering — and the second
      -- must not silently erase the first.
      fixture <- createFixture pool 42 1001
      ref <- withDb pool (openPlan fixture.fxTurn (document "一"))
      first' <- withDb pool (revisePlan ref (Revision 1) CauseChild Nothing (Just fixture.fxTurn) (document "二"))
      first' `shouldBe` Right (Revision 2)
      stale <-
        withDb pool $
          revisePlan ref (Revision 1) CauseSteer (Just fixture.fxPrincipal) Nothing (document "三")
      stale `shouldBe` Left (RevisionConflict (Revision 2))
      -- And the losing write left nothing behind.
      head' <- withDb pool (loadPlanHead ref) >>= requireHead
      head'.stDocument `shouldBe` document "二"

    it "keeps every earlier revision readable, which is what a steer's audit asks" $ do
      fixture <- createFixture pool 42 1001
      ref <- withDb pool (openPlan fixture.fxTurn (document "一"))
      _ <- withDb pool (revisePlan ref (Revision 1) CauseElaboration Nothing Nothing (document "二"))
      _ <- withDb pool (revisePlan ref (Revision 2) CauseSteer (Just fixture.fxPrincipal) Nothing (document "三"))
      history <- rights <$> withDb pool (planHistory ref)
      map (.pheRevision) history `shouldBe` [Revision 3, Revision 2, Revision 1]
      map (.pheCause) history `shouldBe` [CauseSteer, CauseElaboration, CauseInitial]
      -- Attribution: the human is on the steer and on nothing else.
      map (.pheCausedBy) history `shouldBe` [Just fixture.fxPrincipal, Nothing, Nothing]
      -- Distinct documents, so the log is a history and not three pointers to
      -- the same bytes.
      length (Set.fromList (map (.phePlanHash) history)) `shouldBe` 3

    it "records the plan hash the IR itself computes" $ do
      fixture <- createFixture pool 42 1001
      ref <- withDb pool (openPlan fixture.fxTurn (document "一"))
      history <- rights <$> withDb pool (planHistory ref)
      map (.phePlanHash) history `shouldBe` [planHash (document "一").pdPlan]

  describe "closing" $ do
    it "removes a plan from the steerable set without deleting its history" $ do
      fixture <- createFixture pool 42 1001
      ref <- withDb pool (openPlan fixture.fxTurn (document "一"))
      _ <- withDb pool (revisePlan ref (Revision 1) CauseChild Nothing Nothing (document "二"))
      withDb pool (closePlan ref PlanDone)
      open <- withDb pool (listOpenPlans fixture.fxGroup)
      open `shouldBe` []
      head' <- withDb pool (loadPlanHead ref) >>= requireHead
      head'.stStatus `shouldBe` PlanDone
      history <- rights <$> withDb pool (planHistory ref)
      length history `shouldBe` 2

    it "refuses to revise a closed plan rather than reopening it" $ do
      -- Reopening would resurrect children the reconciler has already stopped.
      fixture <- createFixture pool 42 1001
      ref <- withDb pool (openPlan fixture.fxTurn (document "一"))
      withDb pool (closePlan ref PlanAbandoned)
      outcome <- withDb pool (revisePlan ref (Revision 1) CauseSteer Nothing Nothing (document "二"))
      outcome `shouldBe` Left (RevisionConflict (Revision 1))

  describe "listing" $ do
    it "returns open plans in this conversation and no other's" $ do
      here <- createFixture pool 42 1001
      elsewhere <- createFixture pool 43 1002
      _ <- withDb pool (openPlan here.fxTurn (document "这边一"))
      _ <- withDb pool (openPlan here.fxTurn (document "这边二"))
      _ <- withDb pool (openPlan elsewhere.fxTurn (document "那边"))
      open <- rights <$> withDb pool (listOpenPlans here.fxGroup)
      map (\plan -> plan.stDocument.pdPlan) open
        `shouldBe` [(document "这边一").pdPlan, (document "这边二").pdPlan]

  describe "version boundary" $
    it "reports a document this binary cannot read instead of failing to decode it" $ do
      -- A plan written by a newer binary.  Absence and a version boundary are
      -- different answers: a caller that conflated them would quietly drop
      -- work rather than refuse to touch it.
      fixture <- createFixture pool 42 1001
      ref <- withDb pool (openPlan fixture.fxTurn (document "一"))
      _ <- withConn pool $ \connection ->
        execute
          connection
          "UPDATE plan_revisions SET ir_version = ? WHERE plan_id = ?"
          (planIRVersion + 1, ref.prPlanId)
      loaded <- withDb pool (loadPlanHead ref)
      loaded `shouldBe` Just (Left (IRVersionUnsupported (planIRVersion + 1) planIRVersion))

  describe "children" $ do
    it "records a spawn and reads it back as the reconciler's actual side" $ do
      fixture <- createFixture pool 42 1001
      ref <- withDb pool (openPlan fixture.fxTurn (document "一"))
      childTurn <- spawnChild pool fixture ref "查甲" "turn:1:0/k0"
      running <- withDb pool (listRunningChildren ref)
      map (.pcChildTurn) running `shouldBe` [childTurn.atrTurnId]
      map (.pcGoalHash) running `shouldBe` [goalHash (goalNamed "查甲")]
      map (.pcDispatchedNode) running `shouldBe` ["turn:1:0/k0"]

    it "drops a child from the actual side once it has finished, however it finished" $ do
      -- A decided child is the front model's business, not the reconciler's:
      -- stopping one would be stopping nothing.
      fixture <- createFixture pool 42 1001
      ref <- withDb pool (openPlan fixture.fxTurn (document "一"))
      succeeded <- spawnChild pool fixture ref "查甲" "turn:1:0/k0"
      failed <- spawnChild pool fixture ref "查乙" "turn:1:0/k1"
      _ <- spawnChild pool fixture ref "查丙" "turn:1:0/k2"
      withDb pool (finishAgentTurn succeeded TurnSucceeded 1 Nothing Nothing)
      withDb pool (finishAgentTurn failed TurnAborted 1 (Just "killed") Nothing)
      running <- withDb pool (listRunningChildren ref)
      map (.pcGoalHash) running `shouldBe` [goalHash (goalNamed "查丙")]

    it "refuses to record a second parent for one child" $ do
      -- A retry that re-recorded an edge would double-count a running child,
      -- and the reconciler would then stop one of a pair at random.
      fixture <- createFixture pool 42 1001
      ref <- withDb pool (openPlan fixture.fxTurn (document "一"))
      childTurn <- spawnChild pool fixture ref "查甲" "turn:1:0/k0"
      again <-
        try . withDb pool $
          recordChildSpawn ref fixture.fxTurn.atrTurnId childTurn (goalHash (goalNamed "查甲")) "turn:1:0/k0"
      case again of
        Left (_ :: SqlError) -> pure ()
        Right () -> expectationFailure "a child was given two parents"

    it "scopes the actual side to one plan" $ do
      fixture <- createFixture pool 42 1001
      here <- withDb pool (openPlan fixture.fxTurn (document "一"))
      elsewhere <- withDb pool (openPlan fixture.fxTurn (document "二"))
      _ <- spawnChild pool fixture here "查甲" "turn:1:0/k0"
      _ <- spawnChild pool fixture elsewhere "查乙" "turn:1:0/k0"
      running <- withDb pool (listRunningChildren here)
      map (.pcGoalHash) running `shouldBe` [goalHash (goalNamed "查甲")]

    it "feeds a diff that leaves an unchanged subgoal alone and starts the rest" $ do
      -- The two halves meeting: goals out of the stored head, children out of
      -- the spawn edges, and the pure diff over both.
      fixture <- createFixture pool 42 1001
      ref <- withDb pool (openPlan fixture.fxTurn (document "一"))
      _ <- spawnChild pool fixture ref "查甲" "turn:1:0/k0"
      let edited =
            PlanDocument
              { pdRoot = "turn:1:0",
                pdPlan =
                  Fork
                    ForkNode
                      { fnChildren = [(Binder "a", goalNamed "查甲"), (Binder "b", goalNamed "查乙")],
                        fnJoin = JoinAll,
                        fnWatch = WatchOnFailure
                      }
                    (Done (EVar (Binder "a")))
              }
      _ <- withDb pool (revisePlan ref (Revision 1) CauseSteer (Just fixture.fxPrincipal) Nothing edited)
      head' <- withDb pool (loadPlanHead ref) >>= requireHead
      running <- withDb pool (listRunningChildren ref)
      let outcome =
            reconcile
              (desiredChildren head'.stDocument.pdRoot head'.stDocument.pdPlan)
              [Running {rnHash = c.pcGoalHash, rnChild = c.pcChildTurn} | c <- running]
      map (.dsBinder) outcome.rcDispatch `shouldBe` [Binder "b"]
      outcome.rcStop `shouldBe` []
      map (.rnHash) outcome.rcKeep `shouldBe` [goalHash (goalNamed "查甲")]

  describe "suspension" $ do
    it "parks a checkpoint against the revision the execution was walking" $ do
      fixture <- createFixture pool 42 1001
      ref <- withDb pool (openPlan fixture.fxTurn (document "一"))
      parked <- withDb pool (suspendPlan ref (Revision 1) "turn:1:0/k" checkpointState)
      parked `shouldBe` True
      claimed <- claimOne pool ref
      claimed.wpCheckpoint
        `shouldBe` PlanCheckpoint
          {pkNode = "turn:1:0/k", pkRevision = Revision 1, pkState = checkpointState}

    it "refuses a checkpoint whose plan moved while the execution ran" $ do
      -- Between admitting a plan and reaching its fork there is a model round
      -- and several tool calls.  A steer landing in that window produced a
      -- different plan than the one this state walked, and parking against it
      -- would resume a path that describes somebody else's plan.
      fixture <- createFixture pool 42 1001
      ref <- withDb pool (openPlan fixture.fxTurn (document "一"))
      _ <- withDb pool (revisePlan ref (Revision 1) CauseSteer (Just fixture.fxPrincipal) Nothing (document "二"))
      parked <- withDb pool (suspendPlan ref (Revision 1) "turn:1:0/k" checkpointState)
      parked `shouldBe` False
      wakeable <- withDb pool (claimWakeablePlans "w" testTime laterTime 10)
      wakeable `shouldBe` []

    it "drops the checkpoint when the plan closes, in the same act" $ do
      -- A checkpoint outliving its plan is a suspension that would wake into a
      -- conversation which has moved on.  The schema says so too; this is the
      -- writer agreeing with it rather than relying on it.
      fixture <- createFixture pool 42 1001
      ref <- withDb pool (openPlan fixture.fxTurn (document "一"))
      _ <- withDb pool (suspendPlan ref (Revision 1) "turn:1:0/k" checkpointState)
      withDb pool (closePlan ref PlanAbandoned)
      wakeable <- withDb pool (claimWakeablePlans "w" testTime laterTime 10)
      wakeable `shouldBe` []

  describe "waking" $ do
    it "leases a plan that has suspended and dispatched nothing yet" $ do
      fixture <- createFixture pool 42 1001
      ref <- withDb pool (openPlan fixture.fxTurn (document "一"))
      _ <- withDb pool (suspendPlan ref (Revision 1) "turn:1:0/k" checkpointState)
      claimed <- claimOne pool ref
      claimed.wpPlan.stRevision `shouldBe` Revision 1
      claimed.wpGroup `shouldBe` fixture.fxGroup
      claimed.wpInitiator `shouldBe` Just fixture.fxPrincipal
      claimed.wpSeedMessage `shouldSatisfy` (/= Nothing)

    it "holds a lease against a second worker, and hands it over once it lapses" $ do
      fixture <- createFixture pool 42 1001
      ref <- withDb pool (openPlan fixture.fxTurn (document "一"))
      _ <- withDb pool (suspendPlan ref (Revision 1) "turn:1:0/k" checkpointState)
      _ <- claimOne pool ref
      contended <- withDb pool (claimWakeablePlans "other" testTime laterTime 10)
      contended `shouldBe` []
      -- The point of the lease being a deadline rather than a flag: a worker
      -- that died mid-drive must not park a plan forever.
      expired <- withDb pool (claimWakeablePlans "other" muchLaterTime muchLaterTime 10)
      map (fmap (.wpPlan.stRef)) expired `shouldBe` [Right ref]

    it "leaves a plan alone while any of its children is still running" $ do
      -- Both ends of a fork's life look like "no running child" — nothing
      -- dispatched yet, and everything settled.  In between there is nothing
      -- for a driver to decide, so long as nobody has moved the plan: the
      -- watermark is what says this driver already dispatched these.
      fixture <- createFixture pool 42 1001
      ref <- withDb pool (openPlan fixture.fxTurn (document "一"))
      _ <- withDb pool (suspendPlan ref (Revision 1) "turn:1:0/k" checkpointState)
      done' <- spawnChild pool fixture ref "查甲" "turn:1:0/k0"
      _ <- spawnChild pool fixture ref "查乙" "turn:1:0/k1"
      withDb pool (markPlanReconciled ref (Revision 1))
      withDb pool (finishAgentTurn done' TurnSucceeded 1 Nothing Nothing)
      midway <- withDb pool (claimWakeablePlans "w" testTime laterTime 10)
      midway `shouldBe` []

    it "leases it again the moment the last child settles" $ do
      fixture <- createFixture pool 42 1001
      ref <- withDb pool (openPlan fixture.fxTurn (document "一"))
      _ <- withDb pool (suspendPlan ref (Revision 1) "turn:1:0/k" checkpointState)
      _ <- claimOne pool ref
      childTurn <- spawnChild pool fixture ref "查甲" "turn:1:0/k0"
      withDb pool (markPlanReconciled ref (Revision 1))
      withDb pool (releasePlanClaim "w" ref)
      blocked <- withDb pool (claimWakeablePlans "w" testTime laterTime 10)
      blocked `shouldBe` []
      withDb pool (finishAgentTurn childTurn TurnSucceeded 1 Nothing Nothing)
      woken <- withDb pool (claimWakeablePlans "w" testTime laterTime 10)
      map (fmap (.wpPlan.stRef)) woken `shouldBe` [Right ref]

    it "clearing the checkpoint takes the plan out of the wakeable set" $ do
      fixture <- createFixture pool 42 1001
      ref <- withDb pool (openPlan fixture.fxTurn (document "一"))
      _ <- withDb pool (suspendPlan ref (Revision 1) "turn:1:0/k" checkpointState)
      withDb pool (clearPlanCheckpoint ref)
      wakeable <- withDb pool (claimWakeablePlans "w" testTime laterTime 10)
      wakeable `shouldBe` []

    it "wakes with the head as it is now, not as the checkpoint left it" $ do
      -- The steer case the whole revision field exists for: the driver is
      -- entitled to notice that the plan it is resuming is not the one that
      -- parked.
      fixture <- createFixture pool 42 1001
      ref <- withDb pool (openPlan fixture.fxTurn (document "一"))
      _ <- withDb pool (suspendPlan ref (Revision 1) "turn:1:0/k" checkpointState)
      _ <- withDb pool (revisePlan ref (Revision 1) CauseSteer (Just fixture.fxPrincipal) Nothing (document "二"))
      claimed <- claimOne pool ref
      claimed.wpPlan.stRevision `shouldBe` Revision 2
      claimed.wpPlan.stDocument `shouldBe` document "二"
      claimed.wpCheckpoint.pkRevision `shouldBe` Revision 1

  describe "reporting the outcome" $ do
    it "admits exactly one wake and hands the view back to a recovered turn" $ do
      fixture <- createFixture pool 42 1001
      ref <- withDb pool (openPlan fixture.fxTurn (document "一"))
      wake <- withDb pool (startAgentTurn fixture.fxGroup (CanonicalMessageId 0) fixture.fxPrincipal)
      admitted <- withDb pool (admitPlanWake ref wake "计划回来了：甲")
      admitted `shouldBe` True
      withDb pool (loadPlanWake wake.atrTurnId) `shouldReturn` Just "计划回来了：甲"

    it "refuses a second wake, which is what makes the retry safe" $ do
      -- A driver that died after admitting and before closing drives the plan
      -- again, reaches the same result, and must not report it twice: two
      -- answers to one question, and the group cannot tell which is current.
      fixture <- createFixture pool 42 1001
      ref <- withDb pool (openPlan fixture.fxTurn (document "一"))
      first' <- withDb pool (startAgentTurn fixture.fxGroup (CanonicalMessageId 0) fixture.fxPrincipal)
      again <- withDb pool (startAgentTurn fixture.fxGroup (CanonicalMessageId 0) fixture.fxPrincipal)
      withDb pool (admitPlanWake ref first' "第一次") `shouldReturn` True
      withDb pool (admitPlanWake ref again "第二次") `shouldReturn` False
      withDb pool (loadPlanWake first'.atrTurnId) `shouldReturn` Just "第一次"
      withDb pool (loadPlanWake again.atrTurnId) `shouldReturn` Nothing

    it "knows an ordinary turn is not a wake" $ do
      fixture <- createFixture pool 42 1001
      withDb pool (loadPlanWake fixture.fxTurn.atrTurnId) `shouldReturn` Nothing

  describe "child results" $ do
    it "records what a child produced and reads it back beside its status" $ do
      fixture <- createFixture pool 42 1001
      ref <- withDb pool (openPlan fixture.fxTurn (document "一"))
      childTurn <- spawnChild pool fixture ref "查甲" "turn:1:0/k0"
      written <- withDb pool (recordChildResult childTurn.atrTurnId (String "甲的答案"))
      written `shouldBe` True
      -- Still running, so still nobody's result to read.
      withDb pool (listChildOutcomes ref) `shouldReturn` []
      withDb pool (finishAgentTurn childTurn TurnSucceeded 1 Nothing Nothing)
      settled <- withDb pool (listChildOutcomes ref)
      map (.coResult) settled `shouldBe` [Just (String "甲的答案")]
      map (.coGoalHash) settled `shouldBe` [goalHash (goalNamed "查甲")]
      map (.coStatus) settled `shouldBe` ["succeeded"]

    it "leaves a settled child with no result when it never returned one" $ do
      -- A crash, a !kill, or a child that simply said nothing.  All the same
      -- fact to this layer: there is no value, and the plan has to decide what
      -- that means.
      fixture <- createFixture pool 42 1001
      ref <- withDb pool (openPlan fixture.fxTurn (document "一"))
      childTurn <- spawnChild pool fixture ref "查甲" "turn:1:0/k0"
      withDb pool (finishAgentTurn childTurn TurnCrashed 1 (Just "boom") Nothing)
      settled <- withDb pool (listChildOutcomes ref)
      map (.coResult) settled `shouldBe` [Nothing]
      map (.coStatus) settled `shouldBe` ["crashed"]

    it "refuses a result for a turn nobody spawned" $ do
      fixture <- createFixture pool 42 1001
      written <- withDb pool (recordChildResult fixture.fxTurn.atrTurnId (String "x"))
      written `shouldBe` False

  it "reports nothing for a plan that does not exist" $ do
    _ <- createFixture pool 42 1001
    loaded <- withDb pool (loadPlanHead (PlanRef (PlanId 999) (PlanOrdinal 999)))
    loaded `shouldBe` Nothing

-- | A stand-in for a serialized 'Max.Plan.Execute.ExecState'.  Opaque here on
-- purpose: this layer stores the checkpoint and does not read it, and a test
-- that used the real encoding would be asserting the interpreter's business.
checkpointState :: Value
checkpointState =
  object
    [ "path" .= ([] :: [Value]),
      "bindings" .= [object ["name" .= ("hits" :: Text), "value" .= (1 :: Int)]],
      "calls" .= (1 :: Int),
      "sends" .= (0 :: Int)
    ]

laterTime :: UTCTime
laterTime = addUTCTime 60 testTime

muchLaterTime :: UTCTime
muchLaterTime = addUTCTime 3600 testTime

-- | Claim exactly one plan and insist it is the one asked for.
claimOne :: DbPool -> PlanRef -> IO WakeablePlan
claimOne pool ref = do
  claimed <- withDb pool (claimWakeablePlans "w" testTime laterTime 10)
  case claimed of
    [Right plan] | plan.wpPlan.stRef == ref -> pure plan
    other -> fail ("expected exactly this plan to be wakeable, got " <> show (length other))

-- | Open a turn for a subgoal and record the spawn edge, as a scheduler would.
spawnChild :: DbPool -> Fixture -> PlanRef -> Text -> Text -> IO AgentTurnRef
spawnChild pool fixture ref objective node = do
  child <-
    withDb pool $
      startAgentTurn fixture.fxGroup (CanonicalMessageId 0) fixture.fxPrincipal
  withDb pool (markAgentTurnRunning child "child")
  withDb pool (recordChildSpawn ref fixture.fxTurn.atrTurnId child (goalHash (goalNamed objective)) node)
  pure child

requireHead :: Maybe (Either PlanLoadError StoredPlan) -> IO StoredPlan
requireHead = \case
  Just (Right plan) -> pure plan
  Just (Left err) -> fail ("plan did not load: " <> show err)
  Nothing -> fail "expected a plan, found none"

createFixture :: DbPool -> Int64 -> Int64 -> IO Fixture
createFixture pool group messageId = do
  canonical <-
    insertRawMessage pool messageId group (group + 1000) 9 testTime (Just "Alice") "trigger"
  [Only principal] <- withConn pool $ \connection ->
    query
      connection
      "SELECT author_principal_id FROM messages WHERE canonical_message_id = ?"
      (Only canonical)
  turn <- withDb pool (startAgentTurn (GroupId group) (CanonicalMessageId canonical) (PrincipalId principal))
  withDb pool (markAgentTurnRunning turn "test-profile")
  pure Fixture {fxGroup = GroupId group, fxPrincipal = PrincipalId principal, fxTurn = turn}

tshow :: Show a => a -> Text
tshow = T.pack . show
