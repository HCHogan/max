-- | ADR 002's partial-plan IR.
--
-- A 'Plan' is what an elaboration produces and the kernel validates: a spine of
-- tool calls and guards ending in either a value ('Done') or an unelaborated
-- 'Goal' ('Hole').  It is pure data — no runner closures, no @IO@, no host
-- handles — so the same value drives real execution, preview, and symbolic
-- interpretation.
--
-- Three properties are load-bearing and are enforced by construction here
-- rather than by a later check:
--
--   * __Node ids are derived, not authored.__  A node's identity is its path
--     from the plan root ('planNodes'), so a generated plan cannot forge,
--     duplicate, or collide an id with one the journal already used.
--   * __A call does not declare its own result type.__  'CallNode' names a tool
--     and a catalog schema version; the result schema comes from the catalog at
--     validation time.  A model-declared result schema would be a claim the
--     kernel then trusts, which is the whole failure mode the validator exists
--     to prevent.
--   * __Another conversation is inexpressible.__  'ResourceScope' can name the
--     current conversation, a sandbox, a process resource, or an external host
--     — never a second conversation.  Cross-conversation reach is therefore not
--     a check that could be forgotten; there is no syntax for it.
module Max.Plan.Types
  ( -- * Version
    planIRVersion,

    -- * Identity
    NodeId (..),
    PlanStep (..),
    PlanPath (..),
    nodeIdIn,
    Binder (..),

    -- * Expressions
    PlanLit (..),
    litValue,
    Expr (..),
    CompareOp (..),
    Predicate (..),

    -- * Effects and authority
    ResourceScope (..),
    Audience (..),
    PlanEffect (..),
    EffectBudget (..),
    emptyBudget,

    -- * Dependencies
    DependencyKey (..),
    DependencySet (..),
    noDependencies,
    observeDependency,

    -- * Goals, calls, plans
    VerifierRef (..),
    Evidence (..),
    EvidenceSource (..),
    Goal (..),
    CallNode (..),
    ForkNode (..),
    JoinPolicy (..),
    WatchPolicy (..),
    Plan (..),
    PlanNode (..),
    PlanDocument (..),
    planNodes,
    planHoles,
    planChildren,

    -- * Resolved handles
    ValueRef (..),

    -- * Deterministic encoding
    canonicalBytes,
    planHash,
    goalHash,
  )
where

import Crypto.Hash.SHA256 qualified as SHA256
import Data.Aeson
  ( FromJSON (..),
    ToJSON (..),
    Value (..),
    encode,
    object,
    withObject,
    withText,
    (.:),
    (.=),
  )
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Pair, Parser)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Builder qualified as BB
import Data.ByteString.Lazy qualified as BL
import Data.List (intersperse, sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Scientific (Scientific)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Read qualified as T
import Data.Text.Encoding qualified as TE
import Data.Vector qualified as V
-- Constructors stay qualified: 'ToolAuthority' spells its conversation case
-- @CurrentConversation@ too, and the two vocabularies are genuinely different
-- — one is what a tool may consume, the other is what a read may reach.
import Max.Effects.Tools (SchemaVersion (..), ToolAuthority, ToolRef (..))
import Max.Effects.Tools qualified as Tools
import Max.Plan.Schema (PlanSchema)

-- | Bump when an existing construct changes meaning.  Adding a constructor is
-- also a bump: a plan encoded by a newer host must not silently lose a node
-- when decoded by an older one.
-- 2: 'Let'.  An older host would otherwise meet it as an unknown node tag deep
-- inside a document it had already accepted; failing at the envelope says the
-- true thing — this plan is from a language you do not speak.
-- 3: taint removed.  Dropping a field is as much a language change as adding a
-- node: an older host would read a goal with no @declassify@ and default it to
-- something, which is precisely the silent reinterpretation the envelope check
-- exists to prevent.
-- 4: 'Fork', and 'goalResources'.
-- 5: 'Bind', and 'goalInputs'.
planIRVersion :: Int
planIRVersion = 5

-- | A node's stable identity within one turn.  Derived from the plan root the
-- host supplies (the horizon-1 @turn:\<turn_id\>:\<step\>@ id) plus the node's
-- structural path.
newtype NodeId = NodeId {unNodeId :: Text}
  deriving stock (Show, Eq, Ord)

-- | One edge on the walk from the plan root to a node.
data PlanStep
  = -- | Into a 'Call' continuation.
    StepContinue
  | -- | Into a 'Guard' consequent.
    StepThen
  | -- | Into a 'Guard' alternative.
    StepElse
  | -- | Into the n-th subgoal of a 'Fork', counted from zero.
    StepChild !Int
  deriving stock (Show, Eq, Ord)

-- | Root first.
newtype PlanPath = PlanPath {unPlanPath :: [PlanStep]}
  deriving stock (Show, Eq, Ord)

nodeIdIn :: Text -> PlanPath -> NodeId
nodeIdIn root path =
  NodeId (T.intercalate "/" (root : map step path.unPlanPath))
  where
    step = \case
      StepContinue -> "c"
      StepThen -> "t"
      StepElse -> "e"
      StepChild index -> "k" <> T.pack (show index)

-- | A name bound by a 'Call'.  Lexically scoped; the validator rejects
-- shadowing and forward references.
newtype Binder = Binder {unBinder :: Text}
  deriving stock (Show, Eq, Ord)

-- | Literals are scalars only.  Composites are built with 'EArray' and
-- 'EObject' so their size is visible to the cost model instead of hiding
-- inside one opaque blob.
data PlanLit
  = LitText !Text
  | LitInt !Integer
  | LitNumber !Scientific
  | LitBool !Bool
  | LitNull
  deriving stock (Show, Eq)

litValue :: PlanLit -> Value
litValue = \case
  LitText text -> String text
  LitInt n -> Number (fromInteger n)
  LitNumber n -> Number n
  LitBool b -> Bool b
  LitNull -> Null

-- | The total, pure, host-call-free expression language.
--
-- There is no application, no recursion, no unbounded iteration and no name
-- that resolves outside the plan.  Every collection combinator carries its own
-- bound, so a static cost model can price an expression before it runs (see
-- "Max.Plan.Eval").  General computation stays an explicit sandbox 'Call' whose
-- effects the validator can see; it is never smuggled through here.
data Expr
  = ELit !PlanLit
  | -- | A 'Call' result bound earlier on the spine, or a combinator's element.
    EVar !Binder
  | -- | A result handle exactly as written (@t#3:r2@).  Syntax, never
    -- authority: the validator resolves it to a 'ValueRef' under the current
    -- scopes, or rejects the plan.
    EHandle !Text
  | EField !Expr !Text
  | EIndex !Expr !Int
  | EArray ![Expr]
  | EObject ![(Text, Expr)]
  | -- | Text concatenation.
    EConcat ![Expr]
  | ELength !Expr
  | -- | A prefix of an array.  The bound is a literal, so it is static.
    ETake !Int !Expr
  | EMap !Binder !Expr !Expr
  | EFilter !Binder !Expr !Predicate
  | EIf !Predicate !Expr !Expr
  | -- | Nullable elimination: the left operand unless it is null.  Without it,
    -- projecting an optional field would be a dead end.
    ECoalesce !Expr !Expr
  deriving stock (Show, Eq)

data CompareOp
  = OpEq
  | OpNe
  | OpLt
  | OpLe
  | OpGt
  | OpGe
  | OpContains
  | OpPrefix
  | OpSuffix
  deriving stock (Show, Eq, Ord)

data Predicate
  = PBool !Bool
  | PNot !Predicate
  | PAnd ![Predicate]
  | POr ![Predicate]
  | PCompare !CompareOp !Expr !Expr
  | PIsNull !Expr
  | PAll !Binder !Expr !Predicate
  | PAny !Binder !Expr !Predicate
  deriving stock (Show, Eq)

-- | What a read or write reaches.  Note the absence of a second conversation:
-- see the module header.
data ResourceScope
  = CurrentConversation
  | -- | A persistent sandbox handle.
    SandboxScope !Text
  | -- | A host process resource, e.g. a browser session.
    ProcessScope !Text
  | -- | An outside origin, named for the effect manifest an approval binds.
    ExternalScope !Text
  deriving stock (Show, Eq, Ord)

-- | Who sees a visible send.  The conversation is implied — a plan cannot name
-- another one — so this is the whole target vocabulary.
data Audience
  = -- | The conversation the turn belongs to.
    AudienceConversation
  | -- | A direct message to the principal who triggered the turn.
    AudienceSender
  deriving stock (Show, Eq, Ord)

data PlanEffect
  = EffRead !ResourceScope
  | EffWrite !ResourceScope
  | EffSend !Audience
  | EffLLM
  | -- | Capability or context discovery in the named namespace.  Invalidates
    -- assumptions about the elaboration environment, so it is a revalidation
    -- frontier rather than an ordinary effect.
    EffReflect !Text
  deriving stock (Show, Eq, Ord)

-- | The ceiling a hole hands to whatever elaborates it.  Every field is a
-- ceiling, never a target: a plan that would exceed any of them is rejected
-- before execution, and the residual of a deoptimized plan is revalidated
-- against the same numbers.
data EffectBudget = EffectBudget
  { ebEffects :: !(Set PlanEffect),
    ebMaxCalls :: !Int,
    ebMaxSends :: !Int,
    -- | Largest collection any bounded combinator may traverse.
    ebMaxFanout :: !Int,
    ebMaxTokens :: !Int,
    ebMaxWallClockMs :: !Int
  }
  deriving stock (Show, Eq)

-- | A budget that forbids everything.  The base case for narrowing: a child
-- goal starts here and is granted what its parent can spare, so a missing
-- grant fails closed.
emptyBudget :: EffectBudget
emptyBudget =
  EffectBudget
    { ebEffects = Set.empty,
      ebMaxCalls = 0,
      ebMaxSends = 0,
      ebMaxFanout = 0,
      ebMaxTokens = 0,
      ebMaxWallClockMs = 0
    }

-- | Something an elaboration read while deciding.  Recorded by the host from
-- the actual pull traffic, never authored by the model.
data DependencyKey
  = -- | A pulled result handle.
    DepResult !Text
  | -- | A pulled turn record.
    DepTurnRecord !Text
  | DepToolCatalog
  | DepPromptContract
  | -- | A binding named in 'goalInputs', paired with the digest its value had
    -- when the goal was dispatched.  Host-stamped: it is what makes a goal
    -- whose input changed hash differently, and therefore reconcile as new
    -- work rather than as work already running.
    DepBinding !Text
  deriving stock (Show, Eq, Ord)

-- | The observed read-set of one elaboration session, each key paired with the
-- fingerprint it had when read.  A key whose fingerprint moved before execution
-- invalidates the candidate.
newtype DependencySet = DependencySet {unDependencySet :: Map DependencyKey Text}
  deriving stock (Show, Eq)

noDependencies :: DependencySet
noDependencies = DependencySet Map.empty

observeDependency :: DependencyKey -> Text -> DependencySet -> DependencySet
observeDependency key fingerprint deps =
  DependencySet (Map.insert key fingerprint deps.unDependencySet)

-- | Names a host-registered verifier.  Its schema, dependency fingerprint,
-- effect declaration, timeout and output limit live in the host registry, not
-- here — a plan selects a gate, it does not define one.
data VerifierRef = VerifierRef
  { verName :: !Text,
    verVersion :: !Int
  }
  deriving stock (Show, Eq, Ord)

-- | An unelaborated obligation.
data Goal = Goal
  { goalObjective :: !Text,
    goalExpected :: !PlanSchema,
    -- | Acceptance gates.  Empty means "shape is the only postcondition",
    -- which is honest for the first slice but is not the same as "verified".
    goalAcceptance :: ![VerifierRef],
    goalBudget :: !EffectBudget,
    -- | Authority the elaboration may consume, as catalog authority classes.
    goalAuthority :: !(Set ToolAuthority),
    -- | Result handles whoever fills this goal may resolve, by name.
    --
    -- An address, never a body.  A goal that carried the bytes would grow with
    -- whatever it points at and its hash would move with the content, which
    -- would defeat 'goalHash' as an identity — and it would put a page nobody
    -- has decided to read into a prompt.  A handle is thirty tokens and a
    -- schema; whatever fills the goal decides whether to pull it.
    goalResources :: ![Text],
    -- | Bindings from the enclosing plan this goal needs to see.
    --
    -- A fork child sees only its 'Goal', so before this existed there was no
    -- way to hand it a value the parent had computed. A live model found the
    -- gap and worked around it exactly as one would: it inlined an entire
    -- itinerary string into both subgoals' objectives, twice. Fine for a
    -- sentence, and precisely the context bloat a fork exists to avoid for
    -- anything larger.
    --
    -- Names only. The host resolves each to the parent's bound value at
    -- dispatch and stamps its digest into 'goalDeps' — which is what keeps
    -- 'goalHash' honest, since a goal reading a changed input is different
    -- work and must not reconcile as the same.
    goalInputs :: ![Binder],
    goalDeps :: !DependencySet,
    -- | Why a previous attempt at this goal did not complete.  Host-attached
    -- only: see 'Evidence'.
    goalEvidence :: ![Evidence],
    -- | Which elaboration attempt this is.  Re-holing increments it, so the
    -- fuel a goal has already burned travels with the goal instead of living
    -- in a side table that a fork or a restart could lose.
    goalAttempt :: !Int
  }
  deriving stock (Show, Eq)

-- | Why an attempt failed, carried back into the goal that will be retried.
--
-- Evidence is __host-attached, never authored__.  A verifier's output can
-- quote content an attacker controls, so it arrives bounded and scoped — and
-- the validator rejects a model-supplied plan that tries to write any, because
-- evidence a model wrote about itself is not evidence.
data Evidence = Evidence
  { evSource :: !EvidenceSource,
    -- | Already truncated by the host.
    evDetail :: !Text,
    evScope :: !ResourceScope
  }
  deriving stock (Show, Eq)

data EvidenceSource
  = -- | The candidate value did not match the goal's expected schema.
    FromResultSchema
  | -- | The named acceptance verifier did not certify the value.
    FromVerifier !Text
  deriving stock (Show, Eq)

data CallNode = CallNode
  { cnBind :: !Binder,
    cnTool :: !ToolRef,
    -- | The catalog version the plan was written against.  A drifted catalog
    -- invalidates the plan rather than reinterpreting its arguments.
    cnSchemaVersion :: !SchemaVersion,
    cnInput :: !Expr
  }
  deriving stock (Show, Eq)

-- | When a fork's continuation becomes runnable.
--
-- One constructor on purpose.  @any@ — first child to succeed wins, the rest
-- are cancelled — has a real use (racing a fast, rough route against a slow,
-- good one) and no implementation here, because cancellation is a scheduler
-- concern this module does not yet have one of.  The syntax position exists so
-- that adding it later is a new word rather than a new shape.
data JoinPolicy
  = -- | Every child completes before the continuation runs.
    JoinAll
  deriving stock (Show, Eq, Ord)

-- | When whoever owns the plan is woken to look at it.
--
-- Distinct from 'JoinPolicy', and the distinction is the point.  In an @async@
-- runtime the awaiting task is also the consumer, so @join_all@ versus a
-- completion stream is one choice.  Here the consumer is the continuation —
-- pure, free to run — and the observer is a language model, which is neither.
-- Collapsing them would price every observation at a join, or every join at a
-- model call.
-- One constructor, for the same reason 'JoinPolicy' has one — and it did not
-- start that way.  @each@ (wake on every completion, so the plan can be
-- rewritten partway through) was parsed, stored, rendered, and then never acted
-- on, while the guide handed to the model said in as many words that writing it
-- would get the model woken for each child.  A grammar that accepts a word and
-- ignores it is worse than one that has never heard of it: the model cannot see
-- that it did not happen.
--
-- Implementing it is not wiring: the wake is exactly-once by schema —
-- @plans.wake_turn_id@ is one nullable column and admission only matches while
-- it is NULL — so @each@ needs that single column to become a ledger keyed by
-- child, keeping admission as the idempotency point.  Worth doing when
-- something wants it.  Nothing did: in production the plan machinery has opened
-- one plan, ever.
data WatchPolicy
  = -- | Only a child that failed is worth interrupting for.  The quiet default:
    -- a fork whose children all succeed costs no model call at all.
    WatchOnFailure
  deriving stock (Show, Eq, Ord)

-- | A set of subgoals opened at once, and how their completion is handled.
--
-- Every child shares one binding environment — the scope at the fork — so no
-- child can read another's result and the set is independent by construction.
-- Dependent work is two forks, not a flag: what the second one may read is
-- exactly what the first one bound.  Sequencing is therefore derived from the
-- bindings rather than declared, which means a model that got the ordering
-- wrong costs latency and never correctness.
data ForkNode = ForkNode
  { fnChildren :: ![(Binder, Goal)],
    fnJoin :: !JoinPolicy,
    fnWatch :: !WatchPolicy
  }
  deriving stock (Show, Eq)

data Plan
  = -- | A candidate result, not proof the objective was met.
    Done !Expr
  | Call !CallNode !Plan
  | -- | Name a value.  Nothing is invoked and nothing happens: this is the
    -- @let@ of a language with no side effects, and it exists because every
    -- model measured against the dialect reached for it unprompted.  Eight of
    -- the ten real parse failures in the first live run were this and nothing
    -- else.
    --
    -- It costs the kernel nothing to allow.  A pure binding introduces no
    -- effect, spends no call and no send, and its expression is priced by the
    -- same 'exprCost' as any other — so every ceiling still holds, and the
    -- language stays total.  Refusing it bought no safety, only plans that
    -- said the same thing less legibly.
    Let !Binder !Expr !Plan
  | -- | Open several subgoals at once and name each result, then continue with
    -- all of them in scope.
    --
    -- 'Hole' and 'Fork' are both unfinished work, and they are deliberately
    -- separate nodes rather than one with a count.  A hole is filled by
    -- whoever is already writing this plan, with everything it can see; a
    -- fork's child is filled by a separate elaboration that sees only its own
    -- 'Goal'.  That is the difference between thinking further and delegating,
    -- and it is the difference the declarations on the goal only mean anything
    -- under: a child that could read the conversation would not need them.
    Fork !ForkNode !Plan
  | Guard !Predicate !Plan !Plan
  | -- | Name a value this plan cannot write yet, and carry on.
    --
    -- 'Hole' defers the /rest/ of the plan; this defers one value inside it.
    -- The identity @Hole g ≡ Bind x g (Done (EVar x))@ holds, and the two stay
    -- separate because a tail hole is the honest exit models already write
    -- well, while this is the thing they kept reaching for and could not
    -- spell: five of six parse failures across every live run were
    -- @let x = hole …@, from two of three models.
    --
    -- It is filled in place by whoever is writing this plan, which is what
    -- distinguishes it from a fork child. That matters most for the smallest
    -- use, which is not delegation at all: a model wrote
    -- @let topic = hole "…" : text budget { calls: 0, sends: 0, … }@ and then
    -- searched twice with it. Nothing there wants a child turn — only a
    -- filled-in blank — and routing it through a fork would have bought an
    -- isolated context, a journal row and a spawn edge to produce one string.
    Bind !Binder !Goal !Plan
  | Hole !Goal
  deriving stock (Show, Eq)

-- | A node stripped of its continuations, for walks that care about one node at
-- a time: effect inference, preview, budget accounting.
data PlanNode
  = NodeDone !Expr
  | NodeCall !CallNode
  | NodeLet !Binder !Expr
  | NodeFork !JoinPolicy !WatchPolicy
  | -- | One subgoal of the enclosing fork.
    NodeChild !Binder !Goal
  | NodeGuard !Predicate
  | NodeBind !Binder !Goal
  | NodeHole !Goal
  deriving stock (Show, Eq)

-- | Every node with the id derived from its path, in pre-order.
planNodes :: Text -> Plan -> [(NodeId, PlanNode)]
planNodes root = go []
  where
    go path plan =
      let here = nodeIdIn root (PlanPath (reverse path))
       in case plan of
            Done expr -> [(here, NodeDone expr)]
            Call call continuation ->
              (here, NodeCall call) : go (StepContinue : path) continuation
            Let binder expr continuation ->
              (here, NodeLet binder expr) : go (StepContinue : path) continuation
            Fork fork continuation ->
              (here, NodeFork fork.fnJoin fork.fnWatch)
                : [ (nodeIdIn root (PlanPath (reverse (StepChild index : path))), NodeChild binder goal)
                    | (index, (binder, goal)) <- zip [0 ..] fork.fnChildren
                  ]
                <> go (StepContinue : path) continuation
            Guard predicate consequent alternative ->
              (here, NodeGuard predicate)
                : go (StepThen : path) consequent
                <> go (StepElse : path) alternative
            Bind binder goal continuation ->
              (here, NodeBind binder goal) : go (StepContinue : path) continuation
            Hole goal -> [(here, NodeHole goal)]

-- | Goals to elaborate in place, whether they end the plan or sit inside it.
-- Deliberately does not include fork children: see 'planChildren', and 'Fork'
-- for why the two are not one list.
planHoles :: Text -> Plan -> [(NodeId, Goal)]
planHoles root plan =
  [ (nodeId, goal)
    | (nodeId, node) <- planNodes root plan,
      goal <- case node of
        NodeHole goal -> [goal]
        NodeBind _ goal -> [goal]
        _ -> []
  ]

-- | Goals to dispatch to a separate elaboration, each with the name its result
-- binds to in the enclosing plan.
planChildren :: Text -> Plan -> [(NodeId, Binder, Goal)]
planChildren root plan =
  [(nodeId, binder, goal) | (nodeId, NodeChild binder goal) <- planNodes root plan]

-- | The transmitted form of a plan.
--
-- Versioning lives on the envelope rather than on every node: a plan is only
-- ever decoded as a whole, and a per-node version would invite the failure it
-- is meant to prevent — decoding the nodes a host understands and quietly
-- dropping the rest.  A version this host does not know is a decode failure,
-- which deoptimizes the turn instead of executing a plan it half-understands.
data PlanDocument = PlanDocument
  { -- | The horizon-1 node id this plan hangs under, and hence the prefix every
    -- derived 'NodeId' carries.
    pdRoot :: !Text,
    pdPlan :: !Plan
  }
  deriving stock (Show, Eq)

-- | A result handle after the validator proved its scope and schema.  The
-- physical blob reference stays internal to the host; a plan sees only this.
data ValueRef = ValueRef
  { vrHandle :: !Text,
    vrSchema :: !PlanSchema,
    vrScope :: !ResourceScope,
    -- | Content digest and byte length, so a pull can be priced and a change
    -- can be detected without re-reading the body.
    vrDigest :: !Text,
    vrLength :: !Int,
    -- | False once retention released the body; the handle still names the row
    -- but can no longer be bound.
    vrRetained :: !Bool
  }
  deriving stock (Show, Eq)

-- | Canonical JSON: object keys sorted, no insignificant whitespace.  The same
-- plan always produces the same bytes, on any host, in any aeson key order —
-- which is what makes 'planHash' safe to bind an approval to.
canonicalBytes :: ToJSON a => a -> BS.ByteString
canonicalBytes = BL.toStrict . BB.toLazyByteString . canonical . toJSON
  where
    canonical = \case
      Object members ->
        "{"
          <> commas
            [ canonical (String (Key.toText key)) <> ":" <> canonical value
              | (key, value) <- sortOn fst (KeyMap.toList members)
            ]
          <> "}"
      Array items -> "[" <> commas (map canonical (V.toList items)) <> "]"
      -- Scalars have exactly one aeson spelling, so reuse it rather than
      -- re-deriving number and escape formatting.
      scalar -> BB.lazyByteString (encode scalar)
    commas = mconcat . intersperse ","

-- | Binds an approval, a cache entry, or a revalidation to exactly one plan.
planHash :: Plan -> Text
planHash = TE.decodeUtf8 . B16.encode . SHA256.hash . canonicalBytes

-- | A goal's identity, for deciding what an edited plan changed.
--
-- Whatever fills a goal is handed the goal and nothing else, so two goals with
-- these bytes are two requests for the same work.  That is what makes an edit
-- cheap to reconcile: diff the open goals of the old plan against the new one
-- by hash, dispatch what appeared, stop what vanished, and leave the rest
-- running.  Wrapping a goal in a larger one — "do that, then this" — moves it
-- in the tree without touching its bytes, so the work already under way is
-- undisturbed.
--
-- Every field counts, including the host-attached ones: a re-holed goal
-- carrying evidence of a failed attempt is a different request, and a moved
-- dependency fingerprint means the world it was written against moved.
goalHash :: Goal -> Text
goalHash = TE.decodeUtf8 . B16.encode . SHA256.hash . canonicalBytes

-- Codecs.  Every sum is externally tagged under "t" so an unknown tag is a
-- decode failure rather than a silently dropped field.

instance ToJSON NodeId where
  toJSON = toJSON . (.unNodeId)

instance FromJSON NodeId where
  parseJSON = fmap NodeId . parseJSON

instance ToJSON Binder where
  toJSON = toJSON . (.unBinder)

instance FromJSON Binder where
  parseJSON = fmap Binder . parseJSON

-- A path encodes as the string a 'NodeId' would show, minus the root: it is
-- the one part of an execution checkpoint a human reads, and two spellings for
-- one thing is how a checkpoint and a journal row stop lining up.
instance ToJSON PlanStep where
  toJSON =
    toJSON @Text . \case
      StepContinue -> "c"
      StepThen -> "t"
      StepElse -> "e"
      StepChild index -> "k" <> T.pack (show index)

instance FromJSON PlanStep where
  parseJSON = withText "PlanStep" $ \case
    "c" -> pure StepContinue
    "t" -> pure StepThen
    "e" -> pure StepElse
    other -> case T.stripPrefix "k" other of
      Just digits
        | Right (index, "") <- T.decimal digits -> pure (StepChild index)
      _ -> unknownTag "PlanStep" other

instance ToJSON PlanPath where
  toJSON = toJSON . (.unPlanPath)

instance FromJSON PlanPath where
  parseJSON = fmap PlanPath . parseJSON

instance ToJSON PlanLit where
  toJSON = \case
    LitText text -> tagged "text" ["v" .= text]
    LitInt n -> tagged "int" ["v" .= n]
    LitNumber n -> tagged "number" ["v" .= n]
    LitBool b -> tagged "bool" ["v" .= b]
    LitNull -> tagged "null" []

instance FromJSON PlanLit where
  parseJSON = withObject "PlanLit" $ \o ->
    o .: "t" >>= \case
      "text" -> LitText <$> o .: "v"
      "int" -> LitInt <$> o .: "v"
      "number" -> LitNumber <$> o .: "v"
      "bool" -> LitBool <$> o .: "v"
      "null" -> pure LitNull
      other -> unknownTag "PlanLit" other

instance ToJSON Expr where
  toJSON = \case
    ELit lit -> tagged "lit" ["lit" .= lit]
    EVar binder -> tagged "var" ["name" .= binder]
    EHandle handle -> tagged "handle" ["handle" .= handle]
    EField expr name -> tagged "field" ["of" .= expr, "name" .= name]
    EIndex expr index -> tagged "index" ["of" .= expr, "index" .= index]
    EArray items -> tagged "array" ["items" .= items]
    EObject fields ->
      tagged "object" ["fields" .= [object ["name" .= name, "value" .= value] | (name, value) <- fields]]
    EConcat parts -> tagged "concat" ["parts" .= parts]
    ELength expr -> tagged "length" ["of" .= expr]
    ETake count expr -> tagged "take" ["count" .= count, "of" .= expr]
    EMap binder source body -> tagged "map" ["as" .= binder, "over" .= source, "body" .= body]
    EFilter binder source predicate -> tagged "filter" ["as" .= binder, "over" .= source, "keep" .= predicate]
    EIf predicate consequent alternative ->
      tagged "if" ["cond" .= predicate, "then" .= consequent, "else" .= alternative]
    ECoalesce primary fallback -> tagged "coalesce" ["primary" .= primary, "fallback" .= fallback]

instance FromJSON Expr where
  parseJSON = withObject "Expr" $ \o ->
    o .: "t" >>= \case
      "lit" -> ELit <$> o .: "lit"
      "var" -> EVar <$> o .: "name"
      "handle" -> EHandle <$> o .: "handle"
      "field" -> EField <$> o .: "of" <*> o .: "name"
      "index" -> EIndex <$> o .: "of" <*> o .: "index"
      "array" -> EArray <$> o .: "items"
      "object" -> do
        fields <- o .: "fields"
        EObject <$> traverse (withObject "field" (\f -> (,) <$> f .: "name" <*> f .: "value")) fields
      "concat" -> EConcat <$> o .: "parts"
      "length" -> ELength <$> o .: "of"
      "take" -> ETake <$> o .: "count" <*> o .: "of"
      "map" -> EMap <$> o .: "as" <*> o .: "over" <*> o .: "body"
      "filter" -> EFilter <$> o .: "as" <*> o .: "over" <*> o .: "keep"
      "if" -> EIf <$> o .: "cond" <*> o .: "then" <*> o .: "else"
      "coalesce" -> ECoalesce <$> o .: "primary" <*> o .: "fallback"
      other -> unknownTag "Expr" other

instance ToJSON CompareOp where
  toJSON =
    toJSON @Text . \case
      OpEq -> "eq"
      OpNe -> "ne"
      OpLt -> "lt"
      OpLe -> "le"
      OpGt -> "gt"
      OpGe -> "ge"
      OpContains -> "contains"
      OpPrefix -> "prefix"
      OpSuffix -> "suffix"

instance FromJSON CompareOp where
  parseJSON = withText "CompareOp" $ \case
    "eq" -> pure OpEq
    "ne" -> pure OpNe
    "lt" -> pure OpLt
    "le" -> pure OpLe
    "gt" -> pure OpGt
    "ge" -> pure OpGe
    "contains" -> pure OpContains
    "prefix" -> pure OpPrefix
    "suffix" -> pure OpSuffix
    other -> unknownTag "CompareOp" other

instance ToJSON Predicate where
  toJSON = \case
    PBool b -> tagged "bool" ["v" .= b]
    PNot predicate -> tagged "not" ["of" .= predicate]
    PAnd parts -> tagged "and" ["parts" .= parts]
    POr parts -> tagged "or" ["parts" .= parts]
    PCompare op left right -> tagged "compare" ["op" .= op, "left" .= left, "right" .= right]
    PIsNull expr -> tagged "isnull" ["of" .= expr]
    PAll binder source body -> tagged "all" ["as" .= binder, "over" .= source, "body" .= body]
    PAny binder source body -> tagged "any" ["as" .= binder, "over" .= source, "body" .= body]

instance FromJSON Predicate where
  parseJSON = withObject "Predicate" $ \o ->
    o .: "t" >>= \case
      "bool" -> PBool <$> o .: "v"
      "not" -> PNot <$> o .: "of"
      "and" -> PAnd <$> o .: "parts"
      "or" -> POr <$> o .: "parts"
      "compare" -> PCompare <$> o .: "op" <*> o .: "left" <*> o .: "right"
      "isnull" -> PIsNull <$> o .: "of"
      "all" -> PAll <$> o .: "as" <*> o .: "over" <*> o .: "body"
      "any" -> PAny <$> o .: "as" <*> o .: "over" <*> o .: "body"
      other -> unknownTag "Predicate" other

instance ToJSON ResourceScope where
  toJSON = \case
    CurrentConversation -> tagged "conversation" []
    SandboxScope handle -> tagged "sandbox" ["handle" .= handle]
    ProcessScope name -> tagged "process" ["name" .= name]
    ExternalScope origin -> tagged "external" ["origin" .= origin]

instance FromJSON ResourceScope where
  parseJSON = withObject "ResourceScope" $ \o ->
    o .: "t" >>= \case
      "conversation" -> pure CurrentConversation
      "sandbox" -> SandboxScope <$> o .: "handle"
      "process" -> ProcessScope <$> o .: "name"
      "external" -> ExternalScope <$> o .: "origin"
      other -> unknownTag "ResourceScope" other

instance ToJSON Audience where
  toJSON =
    toJSON @Text . \case
      AudienceConversation -> "conversation"
      AudienceSender -> "sender"

instance FromJSON Audience where
  parseJSON = withText "Audience" $ \case
    "conversation" -> pure AudienceConversation
    "sender" -> pure AudienceSender
    other -> unknownTag "Audience" other

instance ToJSON PlanEffect where
  toJSON = \case
    EffRead scope -> tagged "read" ["scope" .= scope]
    EffWrite scope -> tagged "write" ["scope" .= scope]
    EffSend audience -> tagged "send" ["audience" .= audience]
    EffLLM -> tagged "llm" []
    EffReflect namespace -> tagged "reflect" ["namespace" .= namespace]

instance FromJSON PlanEffect where
  parseJSON = withObject "PlanEffect" $ \o ->
    o .: "t" >>= \case
      "read" -> EffRead <$> o .: "scope"
      "write" -> EffWrite <$> o .: "scope"
      "send" -> EffSend <$> o .: "audience"
      "llm" -> pure EffLLM
      "reflect" -> EffReflect <$> o .: "namespace"
      other -> unknownTag "PlanEffect" other

instance ToJSON EffectBudget where
  toJSON budget =
    object
      [ "effects" .= Set.toAscList budget.ebEffects,
        "max_calls" .= budget.ebMaxCalls,
        "max_sends" .= budget.ebMaxSends,
        "max_fanout" .= budget.ebMaxFanout,
        "max_tokens" .= budget.ebMaxTokens,
        "max_wall_clock_ms" .= budget.ebMaxWallClockMs
      ]

instance FromJSON EffectBudget where
  parseJSON = withObject "EffectBudget" $ \o ->
    EffectBudget . Set.fromList
      <$> o .: "effects"
      <*> o .: "max_calls"
      <*> o .: "max_sends"
      <*> o .: "max_fanout"
      <*> o .: "max_tokens"
      <*> o .: "max_wall_clock_ms"

instance ToJSON DependencyKey where
  toJSON = \case
    DepResult handle -> tagged "result" ["handle" .= handle]
    DepTurnRecord handle -> tagged "turn" ["handle" .= handle]
    DepToolCatalog -> tagged "tool_catalog" []
    DepPromptContract -> tagged "prompt_contract" []
    DepBinding name -> tagged "binding" ["name" .= name]

instance FromJSON DependencyKey where
  parseJSON = withObject "DependencyKey" $ \o ->
    o .: "t" >>= \case
      "result" -> DepResult <$> o .: "handle"
      "turn" -> DepTurnRecord <$> o .: "handle"
      "tool_catalog" -> pure DepToolCatalog
      "prompt_contract" -> pure DepPromptContract
      "binding" -> DepBinding <$> o .: "name"
      other -> unknownTag "DependencyKey" other

-- A JSON object cannot key on a sum, so dependencies encode as a list of
-- pairs; 'Map.toAscList' keeps that list canonical.
instance ToJSON DependencySet where
  toJSON deps =
    toJSON
      [ object ["key" .= key, "fingerprint" .= fingerprint]
        | (key, fingerprint) <- Map.toAscList deps.unDependencySet
      ]

instance FromJSON DependencySet where
  parseJSON value = do
    entries <- parseJSON value
    DependencySet . Map.fromList
      <$> traverse (withObject "dependency" (\o -> (,) <$> o .: "key" <*> o .: "fingerprint")) entries

instance ToJSON VerifierRef where
  toJSON verifier = object ["name" .= verifier.verName, "version" .= verifier.verVersion]

instance FromJSON VerifierRef where
  parseJSON = withObject "VerifierRef" $ \o ->
    VerifierRef <$> o .: "name" <*> o .: "version"

authorityJson :: ToolAuthority -> Value
authorityJson = \case
  Tools.CurrentConversation -> tagged "current_conversation" []
  Tools.CurrentEndpoint -> tagged "current_endpoint" []
  Tools.ProcessResource name -> tagged "process_resource" ["name" .= name]

parseAuthority :: Value -> Parser ToolAuthority
parseAuthority = withObject "ToolAuthority" $ \o ->
  o .: "t" >>= \case
    "current_conversation" -> pure Tools.CurrentConversation
    "current_endpoint" -> pure Tools.CurrentEndpoint
    "process_resource" -> Tools.ProcessResource <$> o .: "name"
    other -> unknownTag "ToolAuthority" other

instance ToJSON Goal where
  toJSON goal =
    object
      [ "objective" .= goal.goalObjective,
        "expected" .= goal.goalExpected,
        "acceptance" .= goal.goalAcceptance,
        "budget" .= goal.goalBudget,
        "authority" .= map authorityJson (Set.toAscList goal.goalAuthority),
        "resources" .= goal.goalResources,
        "inputs" .= goal.goalInputs,
        "deps" .= goal.goalDeps,
        "evidence" .= goal.goalEvidence,
        "attempt" .= goal.goalAttempt
      ]

instance FromJSON Goal where
  parseJSON = withObject "Goal" $ \o -> do
    authority <- traverse parseAuthority =<< o .: "authority"
    Goal
      <$> o .: "objective"
      <*> o .: "expected"
      <*> o .: "acceptance"
      <*> o .: "budget"
      <*> pure (Set.fromList authority)
      <*> o .: "resources"
      <*> o .: "inputs"
      <*> o .: "deps"
      <*> o .: "evidence"
      <*> o .: "attempt"

instance ToJSON Evidence where
  toJSON evidence =
    object
      [ "source" .= evidence.evSource,
        "detail" .= evidence.evDetail,
        "scope" .= evidence.evScope
      ]

instance FromJSON Evidence where
  parseJSON = withObject "Evidence" $ \o ->
    Evidence <$> o .: "source" <*> o .: "detail" <*> o .: "scope"

instance ToJSON EvidenceSource where
  toJSON = \case
    FromResultSchema -> tagged "result_schema" []
    FromVerifier name -> tagged "verifier" ["name" .= name]

instance FromJSON EvidenceSource where
  parseJSON = withObject "EvidenceSource" $ \o ->
    o .: "t" >>= \case
      "result_schema" -> pure FromResultSchema
      "verifier" -> FromVerifier <$> o .: "name"
      other -> unknownTag "EvidenceSource" other

instance ToJSON CallNode where
  toJSON call =
    object
      [ "bind" .= call.cnBind,
        "tool" .= call.cnTool.unToolRef,
        "schema_version" .= call.cnSchemaVersion.unSchemaVersion,
        "input" .= call.cnInput
      ]

instance FromJSON CallNode where
  parseJSON = withObject "CallNode" $ \o ->
    CallNode
      <$> o .: "bind"
      <*> (ToolRef <$> o .: "tool")
      <*> (SchemaVersion <$> o .: "schema_version")
      <*> o .: "input"

instance ToJSON JoinPolicy where
  toJSON = toJSON @Text . \case JoinAll -> "all"

instance FromJSON JoinPolicy where
  parseJSON = withText "JoinPolicy" $ \case
    "all" -> pure JoinAll
    other -> unknownTag "JoinPolicy" other

instance ToJSON WatchPolicy where
  toJSON = toJSON @Text . \case WatchOnFailure -> "on_failure"

-- @each@ is refused rather than read as @on_failure@.  A checkpoint carrying it
-- was written by a binary that promised something this one does not do, and
-- quietly downgrading it is the same silent divergence that made the word worth
-- removing.  Refusing means the plan worker leaves it claimed and says so,
-- which is what it already does for anything it cannot read.
instance FromJSON WatchPolicy where
  parseJSON = withText "WatchPolicy" $ \case
    "on_failure" -> pure WatchOnFailure
    other -> unknownTag "WatchPolicy" other

-- Children encode as an ordered list rather than an object keyed by binder:
-- the order is a node id ('StepChild'), so a codec that let a key map reorder
-- them would rename every child that moved.
instance ToJSON ForkNode where
  toJSON fork =
    object
      [ "children"
          .= [object ["as" .= binder, "goal" .= goal] | (binder, goal) <- fork.fnChildren],
        "join" .= fork.fnJoin,
        "watch" .= fork.fnWatch
      ]

instance FromJSON ForkNode where
  parseJSON = withObject "ForkNode" $ \o -> do
    children <- traverse (withObject "child" (\c -> (,) <$> c .: "as" <*> c .: "goal")) =<< o .: "children"
    ForkNode children <$> o .: "join" <*> o .: "watch"

instance ToJSON Plan where
  toJSON = \case
    Done expr -> tagged "done" ["value" .= expr]
    Call call continuation -> tagged "call" ["call" .= call, "then" .= continuation]
    Let binder expr continuation ->
      tagged "let" ["as" .= binder, "value" .= expr, "then" .= continuation]
    Fork fork continuation -> tagged "fork" ["fork" .= fork, "then" .= continuation]
    Guard predicate consequent alternative ->
      tagged "guard" ["cond" .= predicate, "then" .= consequent, "else" .= alternative]
    Bind binder goal continuation ->
      tagged "bind" ["as" .= binder, "goal" .= goal, "then" .= continuation]
    Hole goal -> tagged "hole" ["goal" .= goal]

instance FromJSON Plan where
  parseJSON = withObject "Plan" $ \o ->
    o .: "t" >>= \case
      "done" -> Done <$> o .: "value"
      "call" -> Call <$> o .: "call" <*> o .: "then"
      "let" -> Let <$> o .: "as" <*> o .: "value" <*> o .: "then"
      "fork" -> Fork <$> o .: "fork" <*> o .: "then"
      "guard" -> Guard <$> o .: "cond" <*> o .: "then" <*> o .: "else"
      "bind" -> Bind <$> o .: "as" <*> o .: "goal" <*> o .: "then"
      "hole" -> Hole <$> o .: "goal"
      other -> unknownTag "Plan" other

instance ToJSON PlanDocument where
  toJSON document =
    object
      [ "v" .= planIRVersion,
        "root" .= document.pdRoot,
        "plan" .= document.pdPlan
      ]

instance FromJSON PlanDocument where
  parseJSON = withObject "PlanDocument" $ \o -> do
    version <- o .: "v"
    if version /= planIRVersion
      then fail ("plan IR version " <> show @Int version <> " is not " <> show planIRVersion)
      else PlanDocument <$> o .: "root" <*> o .: "plan"

instance ToJSON ValueRef where
  toJSON ref =
    object
      [ "handle" .= ref.vrHandle,
        "schema" .= ref.vrSchema,
        "scope" .= ref.vrScope,
        "digest" .= ref.vrDigest,
        "length" .= ref.vrLength,
        "retained" .= ref.vrRetained
      ]

instance FromJSON ValueRef where
  parseJSON = withObject "ValueRef" $ \o ->
    ValueRef
      <$> o .: "handle"
      <*> o .: "schema"
      <*> o .: "scope"
      <*> o .: "digest"
      <*> o .: "length"
      <*> o .: "retained"

tagged :: Text -> [Pair] -> Value
tagged name rest = object (("t" .= name) : rest)

unknownTag :: MonadFail m => String -> Text -> m a
unknownTag what tag = fail (what <> ": unknown tag " <> T.unpack tag)
