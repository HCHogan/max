-- | One wake of a parked plan, against a real database and a fake bot.
--
-- 'Max.Plan.Drive' already covers what the decision /is/; what is left, and
-- what only Postgres can answer, is whether the bookkeeping around it holds:
-- does a driven plan stop being wakeable, does a resumed one close, does an
-- abandoned one tell somebody, and — the failure that would be invisible —
-- does a plan whose children have all come back stay out of the queue instead
-- of dispatching them again.
module Max.Plan.WorkerSpec (spec) where

import Data.Aeson (Value (..), object, toJSON, (.=))
import Data.IORef
import Data.Int (Int64)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Database.PostgreSQL.Simple (Only (..), query)
import Data.Text qualified as T
import Data.Time (UTCTime, addUTCTime)
import Effectful (Eff, IOE, (:>), liftIO)
import Helpers (insertRawMessage, testTime, truncateAll, withDb, withDbLog)
import Max.DB.AgentTurn (AgentTurnTerminal (..), finishAgentTurn, markAgentTurnRunning, startAgentTurn)
import Max.DB.Connection (DbPool, withConn)
import Max.DB.Plan
import Max.Plan.Execute (ExecState (..), initialState)
import Max.Plan.Drive (Dispatchable (..))
import Max.Plan.Reconcile (Desired (..))
import Max.Plan.Schema (PlanSchema (..))
import Max.Plan.Types
import Max.Plan.Worker (PlanDriver (..), Resumption (..), drivePlan)
import Max.Platform.Types (CanonicalMessageId (..), PrincipalId (..))
import Max.Turn.Types (AgentTurnId (..), AgentTurnRef (..))
import OneBot.Types (GroupId (..))
import Test.Hspec

data Fixture = Fixture
  { fxGroup :: !GroupId,
    fxPrincipal :: !PrincipalId,
    fxTurn :: !AgentTurnRef
  }

-- | Everything the driver was asked to do, in order.
data Recorded = Recorded
  { rcSpawned :: !(IORef [Text]),
    rcStopped :: !(IORef [Int64]),
    rcResumed :: !(IORef [ExecState]),
    rcWoken :: !(IORef [Value])
  }

newRecorded :: IO Recorded
newRecorded = Recorded <$> newIORef [] <*> newIORef [] <*> newIORef [] <*> newIORef []

-- | A driver that records and answers, so the worker's bookkeeping is what is
-- under test rather than the bot's.
fakeDriver ::
  IOE :> es =>
  Recorded ->
  (WakeablePlan -> ExecState -> Eff es Resumption) ->
  PlanDriver es
fakeDriver recorded resume =
  PlanDriver
    { pdSpawn = \_ desired -> do
        liftIO (modifyIORef' recorded.rcSpawned (<> [desired.dpDesired.dsBinder.unBinder]))
        pure (Just (AgentTurnId 0)),
      pdStop = \_ child -> liftIO (modifyIORef' recorded.rcStopped (<> [child.unAgentTurnId])),
      pdResume = \plan state -> do
        liftIO (modifyIORef' recorded.rcResumed (<> [state]))
        resume plan state,
      pdWake = \_ outcome -> do
        liftIO (modifyIORef' recorded.rcWoken (<> [outcome]))
        pure True
    }

producing :: Text -> WakeablePlan -> ExecState -> Eff es Resumption
producing value _ _ = pure (Produced (String value))

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

-- | A fork of two subgoals at the root, so the checkpoint's path is empty and
-- the children sit at @k0@ and @k1@.
forked :: PlanDocument
forked =
  PlanDocument
    { pdRoot = "turn:1:0",
      pdPlan =
        Fork
          ForkNode
            { fnChildren = [(Binder "jia", goalNamed "查甲"), (Binder "yi", goalNamed "查乙")],
              fnJoin = JoinAll,
              fnWatch = WatchOnFailure
            }
          (Done (EVar (Binder "jia")))
    }

-- | The same shape with named subgoals and positional binders, for the plans a
-- steer replaces the original with.
forkOfNames :: [Text] -> PlanDocument
forkOfNames names =
  PlanDocument
    { pdRoot = "turn:1:0",
      pdPlan =
        Fork
          ForkNode
            { fnChildren = [(Binder binder, goalNamed name) | (binder, name) <- zip binders names],
              fnJoin = JoinAll,
              fnWatch = WatchOnFailure
            }
          (Done (ELit (LitText "完事")))
    }
  where
    binders = ["a", "b", "c", "d"]

spec :: DbPool -> Spec
spec pool = before_ (truncateAll pool) $ describe "Max.Plan.Worker" $ do
  it "dispatches every subgoal of the parked fork and lets the claim go" $ do
    fixture <- createFixture pool 42 1001
    (ref, plan) <- parkedPlan pool fixture
    recorded <- newRecorded
    withDbLog pool (drivePlan "w" (fakeDriver recorded (producing "x")) plan)
    readIORef recorded.rcSpawned `shouldReturn` ["jia", "yi"]
    readIORef recorded.rcResumed `shouldReturn` []
    readIORef recorded.rcWoken `shouldReturn` []
    -- Still parked, and still open: children are what happens next.
    head' <- withDb pool (loadPlanHead ref) >>= requireHead
    head'.stStatus `shouldBe` PlanOpen
    -- The lease is back, so a worker that dies now costs nothing.
    claimOwner pool ref `shouldReturn` Nothing

  it "resumes past the fork once every child has returned a value, then closes" $ do
    fixture <- createFixture pool 42 1001
    (ref, _) <- parkedPlan pool fixture
    settle pool fixture ref [("查甲", Just "甲的答案"), ("查乙", Just "乙的答案")]
    plan <- claimOne pool ref
    recorded <- newRecorded
    withDbLog pool (drivePlan "w" (fakeDriver recorded (producing "甲的答案")) plan)
    -- Nothing re-dispatched: the failure this whole third column exists to
    -- prevent would show up right here as ["jia","yi"] a second time.
    readIORef recorded.rcSpawned `shouldReturn` []
    readIORef recorded.rcResumed >>= \case
      [state] -> do
        state.esPath `shouldBe` PlanPath [StepContinue]
        Map.keys state.esBindings `shouldBe` [Binder "jia", Binder "yi"]
      other -> expectationFailure ("expected one resume, got " <> show (length other))
    readIORef recorded.rcWoken `shouldReturn` [String "甲的答案"]
    head' <- withDb pool (loadPlanHead ref) >>= requireHead
    head'.stStatus `shouldBe` PlanDone
    withDb pool (claimWakeablePlans "w" testTime testTime 10) `shouldReturn` []

  it "parks again when the resumed walk hits another fork" $ do
    fixture <- createFixture pool 42 1001
    (ref, _) <- parkedPlan pool fixture
    settle pool fixture ref [("查甲", Just "一"), ("查乙", Just "二")]
    plan <- claimOne pool ref
    recorded <- newRecorded
    let nextFork _ _ = pure (Parked "turn:1:0/c" (toJSON (initialState {esCalls = 3})))
    withDbLog pool (drivePlan "w" (fakeDriver recorded nextFork) plan)
    readIORef recorded.rcWoken `shouldReturn` []
    -- Open, re-parked at the new node, and claimable again — which is what
    -- makes "do these three, then those two" cost nothing to support.
    again <- claimOne pool ref
    again.wpCheckpoint.pkNode `shouldBe` "turn:1:0/c"
    again.wpPlan.stStatus `shouldBe` PlanOpen

  it "abandons the plan and says so when a child came back with nothing" $ do
    fixture <- createFixture pool 42 1001
    (ref, _) <- parkedPlan pool fixture
    settle pool fixture ref [("查甲", Just "甲的答案"), ("查乙", Nothing)]
    plan <- claimOne pool ref
    recorded <- newRecorded
    withDbLog pool (drivePlan "w" (fakeDriver recorded (producing "x")) plan)
    readIORef recorded.rcResumed `shouldReturn` []
    readIORef recorded.rcWoken >>= \case
      [String told] -> told `shouldSatisfy` T.isInfixOf "yi"
      other -> expectationFailure ("expected one wake, got " <> show (length other))
    head' <- withDb pool (loadPlanHead ref) >>= requireHead
    head'.stStatus `shouldBe` PlanAbandoned

  it "abandons a checkpoint this binary cannot read rather than sitting on it" $ do
    -- Not a hypothetical: the checkpoint is the one thing in this schema whose
    -- encoding belongs to a module that is free to change it.
    fixture <- createFixture pool 42 1001
    ref <- withDb pool (openPlan fixture.fxTurn forked)
    _ <- withDb pool (suspendPlan ref (Revision 1) "turn:1:0" (object ["nonsense" .= True]))
    plan <- claimOne pool ref
    recorded <- newRecorded
    withDbLog pool (drivePlan "w" (fakeDriver recorded (producing "x")) plan)
    readIORef recorded.rcSpawned `shouldReturn` []
    readIORef recorded.rcWoken >>= \told -> length told `shouldBe` 1
    head' <- withDb pool (loadPlanHead ref) >>= requireHead
    head'.stStatus `shouldBe` PlanAbandoned

  describe "a steer that lands while children run" $ do
    it "is claimable at once instead of waiting for them to finish" $ do
      -- Step 11's gate was "no running child", which let an edit sit behind the
      -- very work it was meant to cancel.
      fixture <- createFixture pool 42 1001
      (ref, plan) <- parkedPlan pool fixture
      recorded <- newRecorded
      withDbLog pool (drivePlan "w" (fakeDriver recorded (producing "x")) plan)
      _ <- spawnChild pool fixture ref "查甲" "turn:1:0/k0"
      -- Nothing moved, so nothing to do: the watermark is what stops the
      -- released lease being re-offered forever.
      withDb pool (claimWakeablePlans "w" testTime laterTime 10) `shouldReturn` []
      _ <-
        withDb pool $
          revisePlan ref (Revision 1) CauseSteer (Just fixture.fxPrincipal) Nothing (forkOfNames ["查丙"])
      steered <- claimOne pool ref
      steered.wpPlan.stRevision `shouldBe` Revision 2

    it "stops what the edited plan no longer wants and starts what it does" $ do
      fixture <- createFixture pool 42 1001
      (ref, plan) <- parkedPlan pool fixture
      recorded0 <- newRecorded
      withDbLog pool (drivePlan "w" (fakeDriver recorded0 (producing "x")) plan)
      stray <- spawnChild pool fixture ref "查甲" "turn:1:0/k0"
      _ <- spawnChild pool fixture ref "查乙" "turn:1:0/k1"
      _ <-
        withDb pool $
          revisePlan ref (Revision 1) CauseSteer (Just fixture.fxPrincipal) Nothing (forkOfNames ["查乙", "查丙"])
      steered <- claimOne pool ref
      recorded <- newRecorded
      withDbLog pool (drivePlan "w" (fakeDriver recorded (producing "x")) steered)
      -- 甲 is gone from the plan, so its child is stopped; 乙 survived the edit
      -- untouched and is left alone; 丙 is new and starts now, alongside it.
      readIORef recorded.rcStopped `shouldReturn` [stray.atrTurnId.unAgentTurnId]
      readIORef recorded.rcSpawned `shouldReturn` ["b"]

    it "does not re-offer the same revision once it has been driven" $ do
      fixture <- createFixture pool 42 1001
      (ref, plan) <- parkedPlan pool fixture
      recorded <- newRecorded
      withDbLog pool (drivePlan "w" (fakeDriver recorded (producing "x")) plan)
      _ <- spawnChild pool fixture ref "查甲" "turn:1:0/k0"
      withDb pool (claimWakeablePlans "w" testTime laterTime 10) `shouldReturn` []

  describe "a child that delegates" $ do
    it "is still working while the plan it opened is suspended" $ do
      -- Its turn ended when it submitted a plan that forked.  A parent counting
      -- it as decided would read the missing result as a failure and abandon
      -- over work that is going fine.
      fixture <- createFixture pool 42 1001
      (ref, plan) <- parkedPlan pool fixture
      recorded <- newRecorded
      withDbLog pool (drivePlan "w" (fakeDriver recorded (producing "x")) plan)
      child <- spawnChild pool fixture ref "查甲" "turn:1:0/k0"
      nested <- withDb pool (openPlan child forked)
      _ <- withDb pool (suspendPlan nested (Revision 1) "turn:1:0" (toJSON initialState))
      withDb pool (finishAgentTurn child TurnSucceeded 1 Nothing Nothing)
      -- The parent is not wakeable; only the nested plan is.
      claimed <- withDb pool (claimWakeablePlans "w" testTime laterTime 10)
      map (fmap (.wpPlan.stRef)) claimed `shouldBe` [Right nested]

    it "answers its subgoal with its plan's result instead of telling a model" $ do
      fixture <- createFixture pool 42 1001
      (ref, plan) <- parkedPlan pool fixture
      recorded0 <- newRecorded
      withDbLog pool (drivePlan "w" (fakeDriver recorded0 (producing "x")) plan)
      child <- spawnChild pool fixture ref "查甲" "turn:1:0/k0"
      nested <- withDb pool (openPlan child forked)
      _ <- withDb pool (suspendPlan nested (Revision 1) "turn:1:0" (toJSON initialState))
      withDb pool (finishAgentTurn child TurnSucceeded 1 Nothing Nothing)
      -- Drive the nested plan all the way to a value.
      nestedPlan <- claimOne pool nested
      nestedPlan.wpServesSubgoal `shouldBe` True
      settle pool fixture nested [("查甲", Just "孙一"), ("查乙", Just "孙二")]
      ready <- claimOne pool nested
      recorded <- newRecorded
      withDbLog pool (drivePlan "w" (fakeDriver recorded (producing "孙辈的答案")) ready)
      -- Nobody is told: this plan *is* the subgoal, and its result is the
      -- answer.  Which the parent can now read.
      readIORef recorded.rcWoken `shouldReturn` []
      outcomes <- withDb pool (listChildOutcomes ref)
      map (.coResult) outcomes `shouldBe` [Just (String "孙辈的答案")]

  it "stops a child the plan stopped wanting, and tells nobody twice" $ do
    -- A steer rewrote the plan out from under a running child.  The fork is
    -- gone, so the child's work is not wanted and the plan is over.
    fixture <- createFixture pool 42 1001
    (ref, _) <- parkedPlan pool fixture
    stray <- spawnChild pool fixture ref "查甲" "turn:1:0/k0"
    _ <-
      withDb pool $
        revisePlan
          ref
          (Revision 1)
          CauseSteer
          (Just fixture.fxPrincipal)
          Nothing
          PlanDocument {pdRoot = "turn:1:0", pdPlan = Done (ELit (LitText "算了"))}
    -- The child has to settle before the plan is claimable at all, which is
    -- the limitation the claim gate buys and the module says so.
    withDb pool (finishAgentTurn stray TurnSucceeded 1 Nothing Nothing)
    plan <- claimOne pool ref
    recorded <- newRecorded
    withDbLog pool (drivePlan "w" (fakeDriver recorded (producing "x")) plan)
    readIORef recorded.rcSpawned `shouldReturn` []
    readIORef recorded.rcWoken >>= \told -> length told `shouldBe` 1
    head' <- withDb pool (loadPlanHead ref) >>= requireHead
    head'.stStatus `shouldBe` PlanAbandoned

laterTime :: UTCTime
laterTime = addUTCTime 60 testTime

-- | Open a plan and park it at its fork, then take the lease.
parkedPlan :: DbPool -> Fixture -> IO (PlanRef, WakeablePlan)
parkedPlan pool fixture = do
  ref <- withDb pool (openPlan fixture.fxTurn forked)
  parked <- withDb pool (suspendPlan ref (Revision 1) "turn:1:0" (toJSON initialState))
  parked `shouldBe` True
  (ref,) <$> claimOne pool ref

-- | Run each named subgoal to completion, with or without a value.
settle :: DbPool -> Fixture -> PlanRef -> [(Text, Maybe Text)] -> IO ()
settle pool fixture ref children =
  sequence_
    [ do
        child <- spawnChild pool fixture ref objective ("turn:1:0/k" <> tshow index)
        case answer of
          Just value -> do
            written <- withDb pool (recordChildResult child.atrTurnId (String value))
            written `shouldBe` True
          Nothing -> pure ()
        withDb pool (finishAgentTurn child TurnSucceeded 1 Nothing Nothing)
    | (index :: Int, (objective, answer)) <- zip [0 ..] children
    ]

spawnChild :: DbPool -> Fixture -> PlanRef -> Text -> Text -> IO AgentTurnRef
spawnChild pool fixture ref objective node = do
  child <- withDb pool (startAgentTurn fixture.fxGroup (CanonicalMessageId 0) fixture.fxPrincipal)
  withDb pool (markAgentTurnRunning child "child")
  withDb pool (recordChildSpawn ref fixture.fxTurn.atrTurnId child (goalHash (goalNamed objective)) node)
  pure child

claimOne :: DbPool -> PlanRef -> IO WakeablePlan
claimOne pool ref = do
  claimed <- withDb pool (claimWakeablePlans "w" testTime testTime 10)
  case claimed of
    [Right plan] | plan.wpPlan.stRef == ref -> pure plan
    other -> fail ("expected exactly this plan to be wakeable, got " <> show (length other))

claimOwner :: DbPool -> PlanRef -> IO (Maybe Text)
claimOwner pool ref = do
  rows <- withConn pool $ \connection ->
    query connection "SELECT wake_owner FROM plans WHERE plan_id = ?" (Only ref.prPlanId)
  pure (case rows of [Only owner] -> owner; _ -> Nothing)

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
