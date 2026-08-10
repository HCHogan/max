-- | The environment candidate plans are judged in, and the judging itself.
--
-- Shared by the offline gate ("Main") and the live multi-model run ("Live") so
-- both measure against exactly one world.  If the two binaries each built their
-- own catalog, a difference between an offline rate and a live one could always
-- be blamed on the setup rather than on the model, which would make the
-- comparison worthless.
module Harness
  ( -- * The world
    catalog,
    goal,
    planEnv,

    -- * Judging
    Outcome (..),
    Judged (..),
    ForkShape (..),
    forkShapeOf,
    judge,
    outcomeLabel,
    outcomeDetail,
    outcomeClass,

    -- * Reading a model's reply
    unfence,
    isFenced,
  )
where

import Data.Char (isSpace)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Max.Effects.Tools (SchemaVersion (..), ToolRef (..))
import Max.Effects.Tools qualified as Tools
import Max.Plan.Eval (exprCost)
import Max.Plan.Interpret (EffectManifest, previewPlan)
import Max.Plan.Parse (ParseFailure, parseFailureText, parsePlan)
import Max.Plan.Schema (PlanSchema (..), SchemaField (..))
import Max.Plan.Types
import Max.Plan.Validate

field :: Text -> PlanSchema -> SchemaField
field name schema = SchemaField {sfName = name, sfSchema = schema, sfRequired = True}

optional' :: Text -> PlanSchema -> SchemaField
optional' name schema = SchemaField {sfName = name, sfSchema = schema, sfRequired = False}

-- | A catalog shaped like max's real one, so the numbers mean something.  Kept
-- here rather than in the fixtures: a fixture records what a model wrote, and
-- the environment is the host's business.
catalog :: [CatalogEntry]
catalog =
  [ CatalogEntry
      { ceRef = ToolRef "search_web",
        ceSchemaVersion = SchemaVersion 3,
        ceInput = SchemaObject [field "query" SchemaText, optional' "limit" SchemaInt],
        ceResult = SchemaArray (SchemaObject [field "title" SchemaText, field "url" SchemaText]),
        ceEffects = Set.singleton (EffRead (ExternalScope "web")),
        ceAuthorities = Set.empty
      },
    CatalogEntry
      { ceRef = ToolRef "recall_memory",
        ceSchemaVersion = SchemaVersion 1,
        ceInput = SchemaObject [field "topic" SchemaText],
        ceResult = SchemaText,
        ceEffects = Set.singleton (EffRead CurrentConversation),
        ceAuthorities = Set.singleton Tools.CurrentConversation
      },
    CatalogEntry
      { ceRef = ToolRef "reply",
        ceSchemaVersion = SchemaVersion 1,
        ceInput = SchemaObject [field "text" SchemaText],
        ceResult = SchemaObject [],
        ceEffects = Set.singleton (EffSend AudienceConversation),
        ceAuthorities = Set.singleton Tools.CurrentConversation
      }
  ]

goal :: Goal
goal =
  Goal
    { goalObjective = "回答当前问题",
      goalExpected = SchemaText,
      goalAcceptance = [],
      goalBudget =
        EffectBudget
          { ebEffects =
              Set.fromList
                [ EffRead (ExternalScope "web"),
                  EffRead CurrentConversation,
                  EffSend AudienceConversation
                ],
            ebMaxCalls = 3,
            ebMaxSends = 1,
            ebMaxFanout = 16,
            ebMaxTokens = 8000,
            ebMaxWallClockMs = 30000
          },
      goalAuthority = Set.singleton Tools.CurrentConversation,
      goalResources = [],
      goalDeps = noDependencies,
      goalEvidence = [],
      goalAttempt = 0
    }

planEnv :: ValidationEnv
planEnv =
  ValidationEnv
    { venCatalog = Map.fromList [(entry.ceRef, entry) | entry <- catalog],
      venVerifiers =
        Map.singleton
          "answers-question"
          VerifierEntry {veName = "answers-question", veVersion = 1, veAccepts = SchemaText},
      venHandles = Map.empty,
      venAdmittedVerifiers = Set.singleton "answers-question",
      venGoal = goal,
      venBindings = Map.empty,
      venCostCeiling = 100000
    }

-- | Failures keep their structured form rather than a rendered string, so a
-- caller can group by kind without parsing prose back apart.
data Outcome
  = Unparsed !ParseFailure
  | -- | The plan is carried alongside the reason: a plan that decomposed
    -- correctly and then blew its budget still answers "did this model
    -- decompose", and discarding it would lose that.
    Refused !Rejection !Plan
  | Admitted !EffectManifest !Plan

-- | What a plan did about splitting the work.
--
-- The three numbers ADR 007 step 7 exists to collect. Whether models decompose
-- is not in question — they produce plans and todo lists unprompted, and they
-- already batch parallel tool calls. What is unmeasured is the part a todo
-- list never contains: a declared return type per part, and a combining
-- expression written before any result exists.
data ForkShape = ForkShape
  { fsForks :: !Int,
    fsChildren :: !Int,
    -- | Subgoals asking for something more specific than @text@.
    --
    -- A child declared as @text@ is a child whose result the join can only
    -- concatenate. That is sometimes right and is otherwise the type having
    -- been skipped, so the count is reported rather than scored.
    fsTyped :: !Int,
    -- | A fork whose continuation still contains a hole: the combining step
    -- was punted to another elaboration round.
    --
    -- The case the guide warns about, and the one that decides whether a fork
    -- pays: parallelism bought at the price of an extra model round gives back
    -- the latency it saved.
    fsJoinPunted :: !Int
  }
  deriving stock (Show, Eq)

instance Semigroup ForkShape where
  a <> b =
    ForkShape
      { fsForks = a.fsForks + b.fsForks,
        fsChildren = a.fsChildren + b.fsChildren,
        fsTyped = a.fsTyped + b.fsTyped,
        fsJoinPunted = a.fsJoinPunted + b.fsJoinPunted
      }

instance Monoid ForkShape where
  mempty = ForkShape {fsForks = 0, fsChildren = 0, fsTyped = 0, fsJoinPunted = 0}

forkShapeOf :: Plan -> ForkShape
forkShapeOf = go
  where
    go = \case
      Done _ -> mempty
      Hole _ -> mempty
      Call _ continuation -> go continuation
      Let _ _ continuation -> go continuation
      Guard _ consequent alternative -> go consequent <> go alternative
      Fork fork continuation ->
        ForkShape
          { fsForks = 1,
            fsChildren = length fork.fnChildren,
            fsTyped = length [() | (_, child) <- fork.fnChildren, child.goalExpected /= SchemaText],
            fsJoinPunted = if hasHole continuation then 1 else 0
          }
          <> go continuation

    hasHole = \case
      Hole _ -> True
      Done _ -> False
      Call _ continuation -> hasHole continuation
      Let _ _ continuation -> hasHole continuation
      Fork _ continuation -> hasHole continuation
      Guard _ consequent alternative -> hasHole consequent || hasHole alternative

data Judged = Judged
  { jOutcome :: !Outcome,
    -- | Static cost of every expression, the number the validator prices
    -- against its ceiling.
    jTreeCost :: !Integer,
    -- | Holes left behind: each is a further elaboration round the production
    -- loop would pay for.
    jHoles :: !Int,
    -- | Nothing when the source did not parse.
    jFork :: !(Maybe ForkShape)
  }

-- | Parse, validate, preview — the same three modules, in the same order, that
-- the production path would use.
judge :: Text -> Judged
judge source = case parsePlan source of
  Left failure -> Judged {jOutcome = Unparsed failure, jTreeCost = 0, jHoles = 0, jFork = Nothing}
  Right plan ->
    let -- Both kinds of unfinished work.  Counting only the holes would score a
        -- fan-out as if it were already decided, and the number is here to say
        -- how many further elaborations an answer still costs.
        holes = length (planHoles root plan) + length (planChildren root plan)
        cost =
          sum
            [ exprCost goal.goalBudget.ebMaxFanout expr
              | (_, node) <- planNodes root plan,
                expr <- exprsOf node
            ]
        outcome = case validatePlan planEnv root plan of
          Left rejection -> Refused rejection plan
          Right valid -> Admitted (previewPlan planEnv root valid) plan
     in Judged
          { jOutcome = outcome,
            jTreeCost = cost,
            jHoles = holes,
            jFork = Just (forkShapeOf plan)
          }
  where
    root = "eval:0"
    exprsOf = \case
      NodeDone expr -> [expr]
      NodeCall call -> [call.cnInput]
      NodeLet _ expr -> [expr]
      NodeGuard _ -> []
      -- A fork and its children carry no expression: what they cost is an
      -- elaboration each, which the hole count already reports.
      NodeFork _ _ -> []
      NodeChild _ _ -> []
      NodeHole _ -> []

outcomeLabel :: Outcome -> Text
outcomeLabel = \case
  Unparsed _ -> "unparsed"
  Refused _ _ -> "refused"
  Admitted _ _ -> "admitted"

outcomeDetail :: Outcome -> Text
outcomeDetail = \case
  Unparsed failure -> oneLine (parseFailureText failure)
  Refused rejection _ -> oneLine (rejectionText rejection)
  Admitted _ _ -> ""

-- | A coarse bucket for counting which frontier a model keeps walking into.
--
-- Derived from the constructor name rather than from a hand-written table: a
-- reason added to the kernel classifies itself, where a table would silently
-- lump it under whatever the fallthrough case was.
outcomeClass :: Outcome -> Text
outcomeClass = \case
  Unparsed _ -> "unparsed"
  Refused rejection _ -> T.takeWhile (not . isSpace) (T.pack (show rejection.rjReason))
  Admitted _ _ -> "admitted"

oneLine :: Text -> Text
oneLine = T.unwords . T.words

-- | Whether a reply arrived wrapped in a Markdown code fence.
--
-- Worth counting on its own.  The prompt asks for a bare plan, so a fence is a
-- failure to follow instructions, not a failure to write the dialect — and
-- silently stripping it before measuring would merge the two.
isFenced :: Text -> Bool
isFenced = T.isPrefixOf "```" . T.stripStart

-- | The body inside a fence, or the input unchanged.
unfence :: Text -> Text
unfence raw
  | not (isFenced raw) = T.strip raw
  | otherwise = case T.lines (T.stripStart raw) of
      _opening : rest -> T.strip (T.unlines (dropClosing rest))
      [] -> T.strip raw
  where
    dropClosing = reverse . dropWhile (T.isPrefixOf "```" . T.strip) . reverse
