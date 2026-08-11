-- | Durable ADR 007 plans: the storage half of "history is a graph, intent is
-- a value".
--
-- A plan is the only mutable thing in this design, and it is mutable in
-- exactly one way — its head pointer moves. Every version it ever had stays in
-- @plan_revisions@ with the cause that produced it, so the question a steer's
-- debugging actually asks — /what did the plan look like when that child was
-- dispatched/ — is a query rather than a lost intermediate state.
--
-- Three writers act on one plan while children run: the front model
-- elaborating a hole, a human steering, and a child reporting a result. None
-- may clobber a version it did not read, so every write carries the revision
-- it was based on and 'revisePlan' answers 'RevisionConflict' with the head as
-- it actually is. The caller re-reads and reconciles rather than retrying
-- blind — a conflict means the plan moved, which is information, not noise.
--
-- Two things this module deliberately does not do:
--
--   * __It materializes no open-goal projection.__  Which goals a head wants
--     open is derived by walking the decoded document ('planHoles',
--     'planChildren'), which is microseconds over a plan of a handful of
--     nodes. A table would buy a set difference in SQL at the price of a
--     consistency obligation nothing has yet measured a need for; it is a
--     projection by definition, so it can be added with its first reader.
--   * __It does not interpret the plan.__  Admissibility is
--     "Max.Plan.Validate"'s answer and execution is "Max.Plan.Execute"'s; this
--     module stores documents and moves a pointer.
module Max.DB.Plan
  ( -- * Identity
    PlanId (..),
    PlanOrdinal (..),
    PlanRef (..),
    Revision (..),

    -- * Rows
    PlanStatus (..),
    RevisionCause (..),
    StoredPlan (..),
    PlanHistoryEntry (..),

    -- * Failure
    PlanLoadError (..),
    planLoadErrorText,
    RevisionConflict (..),

    -- * Writing
    openPlan,
    revisePlan,
    closePlan,

    -- * Reading
    loadPlanHead,
    listOpenPlans,
    planHistory,

    -- * Suspension
    PlanCheckpoint (..),
    suspendPlan,
    clearPlanCheckpoint,

    -- * Waking
    WakeablePlan (..),
    claimWakeablePlans,
    markPlanReconciled,
    releasePlanClaim,
    admitPlanWake,
    loadPlanWake,

    -- * Children
    PlanChild (..),
    recordChildSpawn,
    listRunningChildren,
    ChildOutcome (..),
    listChildOutcomes,
    recordChildResult,
  )
where

import Data.Aeson (Result (..), Value, fromJSON, toJSON)
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime)
import Database.PostgreSQL.Simple (Only (..), Query)
import Database.PostgreSQL.Simple.FromField (FromField)
import Database.PostgreSQL.Simple.FromRow (FromRow (..), field)
import Database.PostgreSQL.Simple.ToField (ToField (..), toJSONField)
import Effectful
import Effectful.PostgreSQL (WithConnection, execute, query)
import Max.DB.Transaction (withTransaction)
import Max.Plan.Types (PlanDocument (..), planHash, planIRVersion)
import Max.Platform.Types (PrincipalId (..))
import Max.Turn.Types (AgentTurnId, AgentTurnRef (..))
import OneBot.Types (GroupId (..))

newtype PlanId = PlanId {unPlanId :: Int64}
  deriving stock (Show, Eq, Ord)
  deriving newtype (FromField, ToField)

-- | The conversation-scoped, human-facing number, allocated the way every
-- other ordinal in this schema is.
newtype PlanOrdinal = PlanOrdinal {unPlanOrdinal :: Int64}
  deriving stock (Show, Eq, Ord)
  deriving newtype (FromField, ToField)

data PlanRef = PlanRef
  { prPlanId :: !PlanId,
    prOrdinal :: !PlanOrdinal
  }
  deriving stock (Show, Eq, Ord)

-- | Which version of a plan a writer read, and therefore which one it is
-- entitled to replace.
newtype Revision = Revision {unRevision :: Int}
  deriving stock (Show, Eq, Ord)
  deriving newtype (FromField, ToField)

data PlanStatus
  = -- | Steerable, and the reconciler's business.
    PlanOpen
  | PlanDone
  | PlanAbandoned
  deriving stock (Show, Eq, Ord)

-- | Why the head moved. The causal record: a plan that changed shape between
-- two children's dispatches should say whether a human did that or the machine
-- did.
data RevisionCause
  = -- | The first revision, and only the first: see the table's check.
    CauseInitial
  | -- | A hole was filled in place.
    CauseElaboration
  | -- | A human redirected the work.
    CauseSteer
  | -- | A child returned, and its value was bound.
    CauseChild
  | -- | A goal was re-opened after its result failed acceptance.
    CauseRehole
  deriving stock (Show, Eq, Ord)

causeText :: RevisionCause -> Text
causeText = \case
  CauseInitial -> "initial"
  CauseElaboration -> "elaboration"
  CauseSteer -> "steer"
  CauseChild -> "child"
  CauseRehole -> "rehole"

parseCause :: Text -> Either Text RevisionCause
parseCause = \case
  "initial" -> Right CauseInitial
  "elaboration" -> Right CauseElaboration
  "steer" -> Right CauseSteer
  "child" -> Right CauseChild
  "rehole" -> Right CauseRehole
  other -> Left ("unknown plan revision cause " <> other)

statusText :: PlanStatus -> Text
statusText = \case
  PlanOpen -> "open"
  PlanDone -> "done"
  PlanAbandoned -> "abandoned"

parseStatus :: Text -> Either Text PlanStatus
parseStatus = \case
  "open" -> Right PlanOpen
  "done" -> Right PlanDone
  "abandoned" -> Right PlanAbandoned
  other -> Left ("unknown plan status " <> other)

data StoredPlan = StoredPlan
  { stRef :: !PlanRef,
    -- | The token the next write must present.
    stRevision :: !Revision,
    stStatus :: !PlanStatus,
    stRootTurn :: !AgentTurnId,
    stDocument :: !PlanDocument,
    stUpdatedAt :: !UTCTime
  }
  deriving stock (Show, Eq)

-- | One row of the append-only half, without its document: the shape a history
-- view or a narrator projection reads.
data PlanHistoryEntry = PlanHistoryEntry
  { pheRevision :: !Revision,
    pheCause :: !RevisionCause,
    phePlanHash :: !Text,
    pheCausedBy :: !(Maybe PrincipalId),
    pheCausedByTurn :: !(Maybe AgentTurnId),
    pheCreatedAt :: !UTCTime
  }
  deriving stock (Show, Eq)

-- | A stored document this binary cannot read. Kept separate from "no such
-- plan": one is absence and the other is a version boundary, and a caller that
-- conflated them would silently drop work rather than refuse to touch it.
data PlanLoadError
  = -- | Stored, then what this binary speaks.
    IRVersionUnsupported !Int !Int
  | DocumentUndecodable !Text
  | -- | A row exists but its status text is not one this binary knows.
    StatusUnknown !Text
  deriving stock (Show, Eq)

planLoadErrorText :: PlanLoadError -> Text
planLoadErrorText = \case
  IRVersionUnsupported stored supported ->
    "plan IR version " <> tshow stored <> " is not " <> tshow supported
  DocumentUndecodable detail -> "plan document did not decode: " <> detail
  StatusUnknown detail -> detail

-- | The head moved between the read and the write. Carries where it is now, so
-- the caller reconciles against the current plan instead of re-reading blind.
newtype RevisionConflict = RevisionConflict {rcHead :: Revision}
  deriving stock (Show, Eq)

newtype Jsonb = Jsonb Value

instance ToField Jsonb where
  toField (Jsonb value) = toJSONField value

-- | Open a plan for a turn, with its first revision.
--
-- The conversation comes from the turn rather than from the caller: a plan and
-- its root turn disagreeing about which conversation they are in is a class of
-- bug worth making inexpressible. The conversation row is locked to serialize
-- ordinal allocation, exactly as turn allocation does.
openPlan ::
  (WithConnection :> es, IOE :> es) =>
  AgentTurnRef ->
  PlanDocument ->
  Eff es PlanRef
openPlan turn document = withTransaction $ do
  conversationRows <-
    query
      "SELECT c.conversation_id FROM conversations c \
      \ JOIN agent_turns t ON t.conversation_id = c.conversation_id \
      \ WHERE t.turn_id = ? FOR UPDATE OF c"
      (Only turn.atrTurnId)
  let conversation = exactlyOne "openPlan conversation" (conversationRows :: [Only Int64])
  ordinalRows <-
    query
      "SELECT COALESCE(max(plan_ordinal), 0) + 1 FROM plans WHERE conversation_id = ?"
      (Only conversation)
  let ordinal = exactlyOne "openPlan ordinal" (ordinalRows :: [Only Int64])
  inserted <-
    query
      "INSERT INTO plans (conversation_id, plan_ordinal, root_turn_id) \
      \ VALUES (?, ?, ?) RETURNING plan_id"
      (conversation, ordinal, turn.atrTurnId)
  let planId = exactlyOne "openPlan id" (inserted :: [Only PlanId])
  _ <-
    execute
      "INSERT INTO plan_revisions \
      \ (plan_id, revision, ir_version, plan_hash, document, cause, caused_by_turn_id) \
      \ VALUES (?, 1, ?, ?, ?, 'initial', ?)"
      ( planId,
        planIRVersion,
        planHash document.pdPlan,
        Jsonb (toJSON document),
        turn.atrTurnId
      )
  pure PlanRef {prPlanId = planId, prOrdinal = PlanOrdinal ordinal}

-- | Replace the head, if it is still the revision the caller read.
--
-- Compare-and-set on @head_revision@ rather than a lock held across the
-- caller's thinking: the gap between reading a plan and writing the next one
-- contains a model call, and a transaction spanning that would serialize the
-- whole conversation behind one elaboration.
revisePlan ::
  (WithConnection :> es, IOE :> es) =>
  PlanRef ->
  -- | The revision this write is based on.
  Revision ->
  RevisionCause ->
  -- | The human who caused it, for a steer; nothing when the machine did.
  Maybe PrincipalId ->
  -- | The turn that produced this revision.
  Maybe AgentTurnRef ->
  PlanDocument ->
  Eff es (Either RevisionConflict Revision)
revisePlan ref based cause principal turn document = withTransaction $ do
  moved <-
    query
      "UPDATE plans SET head_revision = head_revision + 1, updated_at = now() \
      \ WHERE plan_id = ? AND head_revision = ? AND status = 'open' \
      \ RETURNING head_revision"
      (ref.prPlanId, based)
  case moved :: [Only Revision] of
    [] -> do
      -- Either the head moved or the plan closed.  Report the head either way;
      -- a closed plan reads as "not the revision you had", which is true and
      -- is the only thing the caller can act on.
      current <-
        query
          "SELECT head_revision FROM plans WHERE plan_id = ?"
          (Only ref.prPlanId)
      pure (Left (RevisionConflict (maybe based fromOnly (listToMaybe' (current :: [Only Revision])))))
    Only next : _ -> do
      _ <-
        execute
          "INSERT INTO plan_revisions \
          \ (plan_id, revision, ir_version, plan_hash, document, cause, \
          \  caused_by_principal_id, caused_by_turn_id) \
          \ VALUES (?, ?, ?, ?, ?, ?, ?, ?)"
          ( ref.prPlanId,
            next,
            planIRVersion,
            planHash document.pdPlan,
            Jsonb (toJSON document),
            causeText cause,
            fmap (.unPrincipalId) principal,
            fmap (.atrTurnId) turn
          )
      pure (Right next)

-- | Take a plan out of the reconciler's view. Idempotent, and refuses to
-- reopen: a closed plan going back to open would resurrect children the
-- reconciler already stopped.
--
-- Closing drops the checkpoint in the same statement, which the schema also
-- insists on. Abandoning a plan and ceasing to drive it are one act: a
-- checkpoint outliving its plan is a suspension that would wake into a
-- conversation which has moved on.
closePlan ::
  (WithConnection :> es, IOE :> es) =>
  PlanRef ->
  -- | 'PlanOpen' is rejected by the schema's check, which is the intent.
  PlanStatus ->
  Eff es ()
closePlan ref status = do
  _ <-
    execute
      "UPDATE plans SET status = ?, closed_at = now(), updated_at = now(), \
      \                 exec_state = NULL, exec_node_id = NULL, exec_revision = NULL, \
      \                 wake_owner = NULL, wake_claim_expires_at = NULL \
      \ WHERE plan_id = ? AND status = 'open'"
      (statusText status, ref.prPlanId)
  pure ()

--------------------------------------------------------------------------------
-- Suspension

-- | Where a plan's execution stands, and which plan it was standing in.
--
-- The state itself is carried as a 'Value' rather than as
-- 'Max.Plan.Execute.ExecState'. This module stores documents and moves
-- pointers; it does not interpret plans, and a checkpoint is exactly as much
-- the interpreter's private business as the plan's node types are.
data PlanCheckpoint = PlanCheckpoint
  { -- | The fork node the walk stopped on. Provenance, and the name a resume
    -- reports when the path no longer resolves.
    pkNode :: !Text,
    -- | The revision the checkpoint was taken against. A steer moves the head
    -- underneath a suspension, so this being behind 'stRevision' is ordinary.
    pkRevision :: !Revision,
    pkState :: !Value
  }
  deriving stock (Show, Eq)

-- | Park a plan's execution at a fork.
--
-- Compare-and-set against the revision the executing turn actually ran, for
-- the same reason 'revisePlan' is: between admitting a plan and reaching its
-- fork there is a model round and several tool calls, and a steer landing in
-- that window produced a different plan than the one this state walked.
-- 'False' means the head moved (or the plan closed) and the caller's checkpoint
-- describes a plan that is no longer current — which is information, not an
-- error.
suspendPlan ::
  (WithConnection :> es, IOE :> es) =>
  PlanRef ->
  -- | The revision this execution was walking.
  Revision ->
  -- | The fork node it stopped on.
  Text ->
  Value ->
  Eff es Bool
suspendPlan ref based node state = do
  moved <-
    execute
      "UPDATE plans \
      \ SET exec_state = ?, exec_node_id = ?, exec_revision = ?, updated_at = now() \
      \ WHERE plan_id = ? AND head_revision = ? AND status = 'open'"
      (Jsonb state, node, based, ref.prPlanId, based)
  pure (moved > 0)

-- | Drop the checkpoint and the wake claim together.
--
-- Called when a resume produced a result or gave up. Unconditional on the
-- head: whatever the plan says now, this execution is no longer parked, and
-- leaving a stale checkpoint behind would have the worker resume a walk whose
-- driver has already returned.
clearPlanCheckpoint ::
  (WithConnection :> es, IOE :> es) =>
  PlanRef ->
  Eff es ()
clearPlanCheckpoint ref = do
  _ <-
    execute
      "UPDATE plans \
      \ SET exec_state = NULL, exec_node_id = NULL, exec_revision = NULL, \
      \     wake_owner = NULL, wake_claim_expires_at = NULL, updated_at = now() \
      \ WHERE plan_id = ?"
      (Only ref.prPlanId)
  pure ()

--------------------------------------------------------------------------------
-- Waking

-- | A suspended plan with something to do, leased to one worker.
data WakeablePlan = WakeablePlan
  { wpPlan :: !StoredPlan,
    -- | The conversation, in the id space a dispatch takes.
    wpGroup :: !GroupId,
    -- | The root turn's trigger, when it had one. A child turn is dispatched
    -- against the same seed message its plan was, so it lands in the right
    -- conversation with a real provenance rather than a synthetic one.
    wpSeedMessage :: !(Maybe Int64),
    wpInitiator :: !(Maybe PrincipalId),
    -- | This plan's root turn is itself somebody's fork child, so whatever the
    -- plan produces is that subgoal's answer rather than something to tell a
    -- model about. What makes fan-out recursive.
    wpServesSubgoal :: !Bool,
    wpCheckpoint :: !PlanCheckpoint
  }
  deriving stock (Show, Eq)

-- | Lease every suspended plan that currently has work to do.
--
-- Two ways to have work, and they are different questions:
--
--   * __No running child.__ Both ends of a fork's life look like this — nothing
--     dispatched yet, or everything settled — and they are when a driver
--     dispatches and when it resumes.
--   * __A head this driver has not reconciled against.__ A steer rewrote the
--     plan while children run: some of them are now working on something the
--     plan no longer asks for, and waiting for them to finish first would let
--     an edit sit behind the work it was meant to cancel.
--
-- The watermark is what keeps the second from spinning. Without it a released
-- lease is immediately re-claimable and the driver reconciles the same
-- revision forever; with it, a claim is only re-offered when somebody moved
-- the head again.
--
-- __A child is not decided while a plan it opened is still suspended.__ Its
-- turn ended, but the work moved from the turn to the plan, and a parent that
-- counted it as settled would read a missing result as a failure.
claimWakeablePlans ::
  (WithConnection :> es, IOE :> es) =>
  -- | Worker identity.
  Text ->
  UTCTime ->
  -- | When this claim lapses, so a worker that dies mid-drive frees its plans.
  UTCTime ->
  Int ->
  Eff es [Either PlanLoadError WakeablePlan]
claimWakeablePlans owner now expires limit = do
  rows <-
    query
      ( "WITH claimed AS ( \
        \  UPDATE plans p SET wake_owner = ?, wake_claim_expires_at = ? \
        \  WHERE p.plan_id IN ( \
        \    SELECT c.plan_id FROM plans c \
        \    WHERE c.status = 'open' AND c.exec_state IS NOT NULL \
        \      AND (c.wake_owner IS NULL OR c.wake_claim_expires_at <= ?) \
        \      AND ( c.head_revision IS DISTINCT FROM c.reconciled_revision \
        \            OR NOT EXISTS (SELECT 1 FROM turn_edges e "
          <> runningChildJoin
          <> "                       WHERE e.edge_kind = 'spawn' AND e.plan_id = c.plan_id \
             \                         AND "
          <> childStillWorking
          <> "                     ) ) \
             \    ORDER BY c.plan_id \
             \    LIMIT ? \
             \    FOR UPDATE SKIP LOCKED \
             \  ) \
             \  RETURNING p.plan_id, p.plan_ordinal, p.head_revision, p.status, p.root_turn_id, \
             \            p.updated_at, p.exec_node_id, p.exec_revision, p.exec_state, p.conversation_id \
             \ ) \
             \ SELECT claimed.plan_id, claimed.plan_ordinal, claimed.head_revision, claimed.status, \
             \        claimed.root_turn_id, r.ir_version, r.document, claimed.updated_at, \
             \        claimed.exec_node_id, claimed.exec_revision, claimed.exec_state, \
             \        conversations.legacy_group_id, root.trigger_canonical_message_id, \
             \        root.initiator_principal_id, \
             \        EXISTS (SELECT 1 FROM turn_edges parent \
             \                WHERE parent.to_turn_id = claimed.root_turn_id \
             \                  AND parent.edge_kind = 'spawn') \
             \ FROM claimed \
             \ JOIN plan_revisions r ON r.plan_id = claimed.plan_id AND r.revision = claimed.head_revision \
             \ JOIN conversations ON conversations.conversation_id = claimed.conversation_id \
             \ JOIN agent_turns root ON root.turn_id = claimed.root_turn_id \
             \ ORDER BY claimed.plan_id"
      )
      (owner, expires, now, limit)
  pure (map decodeWakeable (rows :: [WakeableFields]))

-- | Record that this driver has acted on a revision, so releasing the lease
-- does not immediately re-offer the same decision.
markPlanReconciled ::
  (WithConnection :> es, IOE :> es) =>
  PlanRef ->
  -- | The revision that was actually driven — not the head as it is now, which
  -- may already have moved again and would then never be reconciled.
  Revision ->
  Eff es ()
markPlanReconciled ref revision = do
  _ <-
    execute
      "UPDATE plans SET reconciled_revision = ? WHERE plan_id = ?"
      (revision, ref.prPlanId)
  pure ()

-- | Claim the right to report this plan's outcome, once and only once.
--
-- The idempotency point of the whole wake, and the reason it is here rather
-- than at the close: a driver that dies after admitting is recovered by the
-- turn machinery, and one that dies before it drives the plan again and reaches
-- the same result. 'False' means somebody already admitted a wake — the caller
-- has minted a turn it must now dispose of, and must not dispatch it.
admitPlanWake ::
  (WithConnection :> es, IOE :> es) =>
  PlanRef ->
  AgentTurnRef ->
  -- | The view that turn opens with, stored so a recovered turn gets the same
  -- words rather than a re-derivation that would mean re-running the plan.
  Text ->
  Eff es Bool
admitPlanWake ref turn view = do
  admitted <-
    execute
      "UPDATE plans SET wake_turn_id = ?, wake_view = ? \
      \ WHERE plan_id = ? AND wake_turn_id IS NULL"
      (turn.atrTurnId, view, ref.prPlanId)
  pure (admitted > 0)

-- | The wake a recovered turn belongs to, if it is one.
loadPlanWake ::
  (WithConnection :> es, IOE :> es) =>
  AgentTurnId ->
  Eff es (Maybe Text)
loadPlanWake turnId = do
  rows <- query "SELECT wake_view FROM plans WHERE wake_turn_id = ?" (Only turnId)
  pure (fromOnly <$> listToMaybe' (rows :: [Only Text]))

-- | The join every "is this child still working" test needs.
runningChildJoin :: Query
runningChildJoin = " JOIN agent_turns t ON t.turn_id = e.to_turn_id "

-- | Whether a spawn edge's child is still working.
--
-- Two ways to be, and the second is what makes a child able to delegate: its
-- turn ended the moment it submitted a plan that forked, and the work is now in
-- that plan.  A parent counting it as decided would read the missing result as
-- a failure and abandon over work that is going fine.
childStillWorking :: Query
childStillWorking =
  " ( t.status = ANY (ARRAY['starting', 'running', 'recovery-pending']) \
  \   OR EXISTS (SELECT 1 FROM plans nested \
  \              WHERE nested.root_turn_id = t.turn_id \
  \                AND nested.status = 'open' AND nested.exec_state IS NOT NULL) ) "

-- | Give a lease back without touching the checkpoint.
--
-- The driver's ordinary exit when it dispatched children and has nothing more
-- to do: the plan stays suspended, and the next notification is a child
-- settling rather than this lease expiring.
releasePlanClaim ::
  (WithConnection :> es, IOE :> es) =>
  Text ->
  PlanRef ->
  Eff es ()
releasePlanClaim owner ref = do
  _ <-
    execute
      "UPDATE plans SET wake_owner = NULL, wake_claim_expires_at = NULL \
      \ WHERE plan_id = ? AND wake_owner = ?"
      (ref.prPlanId, owner)
  pure ()

-- | The current plan, or the reason it cannot be read.
loadPlanHead ::
  (WithConnection :> es, IOE :> es) =>
  PlanRef ->
  Eff es (Maybe (Either PlanLoadError StoredPlan))
loadPlanHead ref = do
  rows <-
    query
      (headSelect <> " WHERE p.plan_id = ?")
      (Only ref.prPlanId)
  pure (fmap decodeHead (listToMaybe' (rows :: [HeadFields])))

-- | Every steerable plan in a conversation, oldest first.
listOpenPlans ::
  (WithConnection :> es, IOE :> es) =>
  GroupId ->
  Eff es [Either PlanLoadError StoredPlan]
listOpenPlans (GroupId legacyGroup) = do
  rows <-
    query
      ( headSelect
          <> " WHERE p.status = 'open' \
             \ AND p.conversation_id = (SELECT conversation_id FROM conversations WHERE legacy_group_id = ?) \
             \ ORDER BY p.plan_ordinal"
      )
      (Only legacyGroup)
  pure (map decodeHead (rows :: [HeadFields]))

-- | The append-only half, newest first. Documents are omitted: a history view
-- wants the shape of the sequence, and loading every version of every plan to
-- render one is how a debugging surface becomes the reason for an outage.
planHistory ::
  (WithConnection :> es, IOE :> es) =>
  PlanRef ->
  Eff es [Either Text PlanHistoryEntry]
planHistory ref = do
  rows <-
    query
      "SELECT revision, cause, plan_hash, caused_by_principal_id, caused_by_turn_id, created_at \
      \ FROM plan_revisions WHERE plan_id = ? ORDER BY revision DESC"
      (Only ref.prPlanId)
  pure (map entry rows)
  where
    entry (revision, cause, hash, principal, turn, created) =
      (\parsed -> PlanHistoryEntry revision parsed hash (fmap PrincipalId principal) turn created)
        <$> parseCause cause

-- | A child turn opened by one of this plan's forks.
data PlanChild = PlanChild
  { pcChildTurn :: !AgentTurnId,
    -- | The subgoal it is serving, by content. The reconciler's key.
    pcGoalHash :: !Text,
    -- | Where that subgoal sat when the child was dispatched. Provenance for
    -- the journal, deliberately not the identity: an edit that moves a goal
    -- must not orphan the child already working on it.
    pcDispatchedNode :: !Text
  }
  deriving stock (Show, Eq)

-- | Record that a fork opened a child.
--
-- The unique index on the child turn makes this once-only: a retry that
-- re-recorded an edge would double-count a running child, and the reconciler
-- would then stop one of a pair at random.
recordChildSpawn ::
  (WithConnection :> es, IOE :> es) =>
  PlanRef ->
  -- | The turn whose plan contains the fork. Not necessarily the plan's root:
  -- a nested fork's parent is itself a child.  An id rather than a ref, because
  -- the ordinal is the model-facing handle and nothing here writes one.
  AgentTurnId ->
  -- | The turn opened for the subgoal.
  AgentTurnRef ->
  -- | 'Max.Plan.Types.goalHash' of the subgoal.
  Text ->
  -- | The node id the subgoal was dispatched under.
  Text ->
  Eff es ()
recordChildSpawn ref parent child hash node = do
  _ <-
    execute
      "INSERT INTO turn_edges \
      \ (conversation_id, from_turn_id, to_turn_id, edge_kind, plan_id, goal_hash, dispatched_node_id) \
      \ SELECT p.conversation_id, ?, ?, 'spawn', p.plan_id, ?, ? \
      \ FROM plans p WHERE p.plan_id = ?"
      (parent, child.atrTurnId, hash, node, ref.prPlanId)
  pure ()

-- | The reconciler's actual side: children of this plan that have not
-- finished.
--
-- A finished child is not "actual" whatever it finished as. Succeeded, failed
-- and aborted are all decided, and a decided child is the front model's
-- business rather than the reconciler's — stopping one would be stopping
-- nothing.
listRunningChildren ::
  (WithConnection :> es, IOE :> es) =>
  PlanRef ->
  Eff es [PlanChild]
listRunningChildren ref = do
  rows <-
    query
      ( "SELECT e.to_turn_id, e.goal_hash, e.dispatched_node_id FROM turn_edges e "
          <> runningChildJoin
          <> " WHERE e.edge_kind = 'spawn' AND e.plan_id = ? AND "
          <> childStillWorking
          <> " ORDER BY e.edge_id"
      )
      (Only ref.prPlanId)
  pure [PlanChild turn hash node | (turn, hash, node) <- rows]

-- | A child that has finished, however it finished.
data ChildOutcome = ChildOutcome
  { coChildTurn :: !AgentTurnId,
    coGoalHash :: !Text,
    coDispatchedNode :: !Text,
    -- | The turn's terminal status, verbatim. Kept as text because what the
    -- driver does with it is decide between "there is a value" and "there is
    -- not", and every distinction finer than that belongs to whoever renders
    -- the failure.
    coStatus :: !Text,
    -- | What the child returned, when it returned anything. A settled child
    -- with no result is one that crashed, was killed, or chose to say nothing
    -- — all of which are the plan's problem rather than this module's.
    coResult :: !(Maybe Value)
  }
  deriving stock (Show, Eq)

-- | Children of this plan that are decided, oldest edge first.
listChildOutcomes ::
  (WithConnection :> es, IOE :> es) =>
  PlanRef ->
  Eff es [ChildOutcome]
listChildOutcomes ref = do
  rows <-
    query
      ( "SELECT e.to_turn_id, e.goal_hash, e.dispatched_node_id, t.status, e.child_result FROM turn_edges e "
          <> runningChildJoin
          <> " WHERE e.edge_kind = 'spawn' AND e.plan_id = ? AND NOT "
          <> childStillWorking
          <> " ORDER BY e.edge_id"
      )
      (Only ref.prPlanId)
  pure [ChildOutcome turn hash node status result | (turn, hash, node, status, result) <- rows]

-- | Record what a child produced, on the edge that spawned it.
--
-- Keyed by the child turn, which the unique spawn index makes single-valued —
-- a child cannot serve two plans, so there is no ambiguity about whose result
-- this is. 'False' means the turn is not a spawn child, which is what a
-- non-child turn calling the return tool would look like.
recordChildResult ::
  (WithConnection :> es, IOE :> es) =>
  AgentTurnId ->
  Value ->
  Eff es Bool
recordChildResult child result = do
  written <-
    execute
      "UPDATE turn_edges SET child_result = ? \
      \ WHERE to_turn_id = ? AND edge_kind = 'spawn'"
      (Jsonb result, child)
  pure (written > 0)

-- The head is a join: `plans` holds no document, so that a revision and the
-- pointer to it cannot disagree.
headSelect :: Query
headSelect =
  "SELECT p.plan_id, p.plan_ordinal, p.head_revision, p.status, p.root_turn_id, \
    \       r.ir_version, r.document, p.updated_at \
    \ FROM plans p JOIN plan_revisions r \
    \   ON r.plan_id = p.plan_id AND r.revision = p.head_revision"

data HeadFields = HeadFields
  { hfPlanId :: !PlanId,
    hfOrdinal :: !PlanOrdinal,
    hfRevision :: !Revision,
    hfStatus :: !Text,
    hfRootTurn :: !AgentTurnId,
    hfIRVersion :: !Int,
    hfDocument :: !Value,
    hfUpdatedAt :: !UTCTime
  }

instance FromRow HeadFields where
  fromRow =
    HeadFields
      <$> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field

decodeHead :: HeadFields -> Either PlanLoadError StoredPlan
decodeHead row
  | row.hfIRVersion /= planIRVersion =
      Left (IRVersionUnsupported row.hfIRVersion planIRVersion)
  | otherwise = do
      status <- either (Left . StatusUnknown) Right (parseStatus row.hfStatus)
      document <- case fromJSON row.hfDocument of
        Error detail -> Left (DocumentUndecodable (T.pack detail))
        Success value -> Right value
      pure
        StoredPlan
          { stRef = PlanRef {prPlanId = row.hfPlanId, prOrdinal = row.hfOrdinal},
            stRevision = row.hfRevision,
            stStatus = status,
            stRootTurn = row.hfRootTurn,
            stDocument = document,
            stUpdatedAt = row.hfUpdatedAt
          }

-- A claimed row is a head row plus the checkpoint and the dispatch coordinates
-- a child turn needs. Spelled out rather than composed from 'HeadFields'
-- because postgresql-simple's 'FromRow' is positional, and a nested instance
-- would silently re-order under an edit to either query.
data WakeableFields = WakeableFields
  { wfHead :: !HeadFields,
    wfNode :: !Text,
    wfRevision :: !Revision,
    wfState :: !Value,
    wfGroup :: !(Maybe Int64),
    wfSeedMessage :: !(Maybe Int64),
    wfInitiator :: !(Maybe Int64),
    wfServesSubgoal :: !Bool
  }

instance FromRow WakeableFields where
  fromRow =
    WakeableFields
      <$> fromRow
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field

decodeWakeable :: WakeableFields -> Either PlanLoadError WakeablePlan
decodeWakeable row = do
  stored <- decodeHead row.wfHead
  -- A conversation with no legacy group id cannot be dispatched into, and a
  -- plan is only ever opened from a turn that was. Reported as an undecodable
  -- row rather than crashed on: the worker skips it and says so.
  group <- maybe (Left (DocumentUndecodable "plan conversation has no group id")) Right row.wfGroup
  pure
    WakeablePlan
      { wpPlan = stored,
        wpGroup = GroupId group,
        wpSeedMessage = row.wfSeedMessage,
        wpInitiator = PrincipalId <$> row.wfInitiator,
        wpServesSubgoal = row.wfServesSubgoal,
        wpCheckpoint =
          PlanCheckpoint
            { pkNode = row.wfNode,
              pkRevision = row.wfRevision,
              pkState = row.wfState
            }
      }

listToMaybe' :: [a] -> Maybe a
listToMaybe' = \case
  x : _ -> Just x
  [] -> Nothing

exactlyOne :: Text -> [Only a] -> a
exactlyOne _ [Only value] = value
exactlyOne label rows =
  error (T.unpack label <> ": expected one row, got " <> show (length rows))

tshow :: Show a => a -> Text
tshow = T.pack . show
