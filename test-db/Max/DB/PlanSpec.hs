module Max.DB.PlanSpec (spec) where

import Control.Concurrent.Async (mapConcurrently)
import Data.Either (rights)
import Data.Int (Int64)
import Data.List (sort)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
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
          recordChildSpawn ref fixture.fxTurn childTurn (goalHash (goalNamed "查甲")) "turn:1:0/k0"
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

  it "reports nothing for a plan that does not exist" $ do
    _ <- createFixture pool 42 1001
    loaded <- withDb pool (loadPlanHead (PlanRef (PlanId 999) (PlanOrdinal 999)))
    loaded `shouldBe` Nothing

-- | Open a turn for a subgoal and record the spawn edge, as a scheduler would.
spawnChild :: DbPool -> Fixture -> PlanRef -> Text -> Text -> IO AgentTurnRef
spawnChild pool fixture ref objective node = do
  child <-
    withDb pool $
      startAgentTurn fixture.fxGroup (CanonicalMessageId 0) fixture.fxPrincipal
  withDb pool (markAgentTurnRunning child "child")
  withDb pool (recordChildSpawn ref fixture.fxTurn child (goalHash (goalNamed objective)) node)
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
