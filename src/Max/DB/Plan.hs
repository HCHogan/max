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

    -- * Children
    PlanChild (..),
    recordChildSpawn,
    listRunningChildren,
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
closePlan ::
  (WithConnection :> es, IOE :> es) =>
  PlanRef ->
  -- | 'PlanOpen' is rejected by the schema's check, which is the intent.
  PlanStatus ->
  Eff es ()
closePlan ref status = do
  _ <-
    execute
      "UPDATE plans SET status = ?, closed_at = now(), updated_at = now() \
      \ WHERE plan_id = ? AND status = 'open'"
      (statusText status, ref.prPlanId)
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
  -- a nested fork's parent is itself a child.
  AgentTurnRef ->
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
      (parent.atrTurnId, child.atrTurnId, hash, node, ref.prPlanId)
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
      "SELECT e.to_turn_id, e.goal_hash, e.dispatched_node_id \
      \ FROM turn_edges e JOIN agent_turns t ON t.turn_id = e.to_turn_id \
      \ WHERE e.edge_kind = 'spawn' AND e.plan_id = ? \
      \   AND t.status = ANY (ARRAY['starting', 'running', 'recovery-pending']) \
      \ ORDER BY e.edge_id"
      (Only ref.prPlanId)
  pure [PlanChild turn hash node | (turn, hash, node) <- rows]

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
