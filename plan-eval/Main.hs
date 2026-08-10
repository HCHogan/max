-- | Offline evaluation for ADR 002's plan core — E5's exit gate.
--
-- ADR 002 step 8 says a recorded replay set must measure a plan-enabled loop
-- before any of it runs in production.  This is the offline half of that: no
-- LLM, no database, no network, no effects.  It runs candidate segments
-- through exactly the modules the production path would use — parse, kernel,
-- preview — and reports the numbers E5's exit gate names.
--
-- __Read the rates as properties of the fixtures, not of any model.__  The
-- starter set is hand-authored: written against the kernel's behaviour, so of
-- course it agrees with the kernel.  A parse rate of 81% means 19% of the
-- fixtures were written to be malformed, and nothing more.  That makes this a
-- regression gate — break the parser or the validator and it goes red — and
-- emphatically not evidence that a model can produce admissible plans.  That
-- evidence requires candidates max actually wrote, which requires an
-- elaboration path, which is gated on this harness existing first.
--
-- It also cannot measure answer quality, because nothing here produces an
-- answer; the hole count is a structural proxy and is labelled as one.
module Main (main) where

import Data.Aeson (FromJSON (..), eitherDecodeStrict', withObject, (.:), (.:?))
import Data.ByteString.Char8 qualified as BS8
import Data.List (intercalate)
import Data.Map.Strict qualified as Map
import Data.Foldable (for_)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Max.Context (estimateMessagesTokens)
import Max.Effects.LLM (ChatMessage (..))
import Max.Effects.Tools (SchemaVersion (..), ToolRef (..))
import Max.Effects.Tools qualified as Tools
import Max.Plan.Eval (exprCost)
import Max.Plan.Interpret (EffectManifest (..), PreviewStep (..), Reachability (..), previewPlan)
import Max.Plan.Parse (parseFailureText, parsePlan)
import Max.Plan.Prompt (elaborationPrompt, renderEffect)
import Max.Plan.Schema (PlanSchema (..), SchemaField (..))
import Max.Plan.Types
import Max.Plan.Validate
import System.Environment (getArgs)
import System.Exit (exitFailure, exitSuccess)

-- | One candidate segment.  Either something max wrote and we kept, or — for
-- the starter set — something hand-authored to pin one kernel behaviour.  The
-- harness cannot tell the difference, so the provenance has to be remembered
-- when reading the rates.
data Fixture = Fixture
  { fxName :: !Text,
    fxSource :: !Text,
    -- | @admitted@, @unparsed@ or @refused@.
    fxExpect :: !Text,
    -- | Tokens the horizon-1 loop spent reaching the same point, when the
    -- recording carried it.  Context occupancy is meaningless without it.
    fxBaselineTokens :: !(Maybe Int),
    fxNote :: !(Maybe Text)
  }

instance FromJSON Fixture where
  parseJSON = withObject "Fixture" $ \o ->
    Fixture
      <$> o .: "name"
      <*> o .: "source"
      <*> o .: "expect"
      <*> o .:? "baseline_tokens"
      <*> o .:? "note"

data Outcome = Unparsed !Text | Refused !Text | Admitted !EffectManifest !Plan

outcomeLabel :: Outcome -> Text
outcomeLabel = \case
  Unparsed _ -> "unparsed"
  Refused _ -> "refused"
  Admitted _ _ -> "admitted"

data Row = Row
  { rowFixture :: !Fixture,
    rowOutcome :: !Outcome,
    -- | Estimated tokens the candidate surface occupies.
    rowTokens :: !Int,
    -- | Static cost of every expression in the plan, the number the validator
    -- prices against its ceiling.
    rowTreeCost :: !Integer,
    -- | Holes left behind: each one is a further elaboration round, which is a
    -- deoptimization the production loop would have to pay for.
    rowHoles :: !Int
  }

field :: Text -> PlanSchema -> SchemaField
field name schema = SchemaField {sfName = name, sfSchema = schema, sfRequired = True}

optional' :: Text -> PlanSchema -> SchemaField
optional' name schema = SchemaField {sfName = name, sfSchema = schema, sfRequired = False}

-- | A catalog shaped like max's real one, so the numbers mean something.  Kept
-- here rather than in the fixtures: the fixtures record what a model wrote, and
-- the environment is the host's business.
catalog :: [CatalogEntry]
catalog =
  [ CatalogEntry
      { ceRef = ToolRef "search_web",
        ceSchemaVersion = SchemaVersion 3,
        ceInput = SchemaObject [field "query" SchemaText, optional' "limit" SchemaInt],
        ceResult = SchemaArray (SchemaObject [field "title" SchemaText, field "url" SchemaText]),
        ceEffects = Set.singleton (EffRead (ExternalScope "web")),
        ceAuthorities = Set.empty,
        ceIntroduces = Taint (Set.singleton TaintExternal)
      },
    CatalogEntry
      { ceRef = ToolRef "recall_memory",
        ceSchemaVersion = SchemaVersion 1,
        ceInput = SchemaObject [field "topic" SchemaText],
        ceResult = SchemaText,
        ceEffects = Set.singleton (EffRead CurrentConversation),
        ceAuthorities = Set.singleton Tools.CurrentConversation,
        ceIntroduces = Taint (Set.singleton TaintPrivate)
      },
    CatalogEntry
      { ceRef = ToolRef "reply",
        ceSchemaVersion = SchemaVersion 1,
        ceInput = SchemaObject [field "text" SchemaText],
        ceResult = SchemaObject [],
        ceEffects = Set.singleton (EffSend AudienceConversation),
        ceAuthorities = Set.singleton Tools.CurrentConversation,
        ceIntroduces = untainted
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
      goalDeclassify = Taint (Set.singleton TaintExternal),
      goalDeps = noDependencies,
      goalEvidence = [],
      goalAttempt = 0
    }

env :: ValidationEnv
env =
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

evaluate :: Fixture -> Row
evaluate fixture =
  case parsePlan fixture.fxSource of
    Left failure -> row (Unparsed (oneLine (parseFailureText failure))) 0 0
    Right plan ->
      let holes = length (planHoles root plan)
          cost = sum [exprCost goal.goalBudget.ebMaxFanout expr | (_, node) <- planNodes root plan, expr <- exprsOf node]
       in case validatePlan env root plan of
            Left rejection -> row (Refused (oneLine (rejectionText rejection))) cost holes
            Right valid -> row (Admitted (previewPlan env root valid) plan) cost holes
  where
    root = "eval:0"
    row outcome cost holes =
      Row
        { rowFixture = fixture,
          rowOutcome = outcome,
          rowTokens = estimateMessagesTokens [MsgUser fixture.fxSource],
          rowTreeCost = cost,
          rowHoles = holes
        }
    exprsOf = \case
      NodeDone expr -> [expr]
      NodeCall call -> [call.cnInput]
      NodeGuard _ -> []
      NodeHole _ -> []

main :: IO ()
main = do
  args <- getArgs
  case args of
    -- The bytes a model would be handed, printed from the same environment the
    -- fixtures are judged against.  Worth being able to read directly: this is
    -- the artifact under test as much as the kernel is.
    ["--prompt"] -> putStrLn (T.unpack (elaborationPrompt env))
    _ -> runFixtures args

runFixtures :: [String] -> IO ()
runFixtures args = do
  let path = case args of
        [] -> "plan-eval/fixtures/segments.jsonl"
        (given : _) -> given
  raw <- BS8.readFile path
  let entries = [line | line <- BS8.lines raw, not (BS8.null (BS8.filter (/= ' ') line))]
  fixtures <- traverse decodeLine entries
  let rows = map evaluate fixtures
  mapM_ report rows
  putStrLn ""
  summarize rows
  if all agrees rows then exitSuccess else exitFailure
  where
    decodeLine line = case eitherDecodeStrict' line of
      Left err -> fail ("bad fixture: " <> err)
      Right fixture -> pure fixture

agrees :: Row -> Bool
agrees row = outcomeLabel row.rowOutcome == row.rowFixture.fxExpect

report :: Row -> IO ()
report row = do
  putStrLn (mark <> " " <> T.unpack row.rowFixture.fxName)
  putStrLn ("    outcome    " <> T.unpack (outcomeLabel row.rowOutcome) <> expected)
  case row.rowOutcome of
    Unparsed detail -> putStrLn ("    reason     " <> T.unpack detail)
    Refused detail -> putStrLn ("    reason     " <> T.unpack detail)
    Admitted manifest _ -> do
      putStrLn
        ( "    effects    "
            <> intercalate ", " [T.unpack (renderEffect effect) | effect <- Set.toAscList manifest.emEffects]
        )
      putStrLn
        ( "    calls      "
            <> show manifest.emMaxCalls
            <> " worst-path, "
            <> show (length [() | step <- manifest.emSteps, step.psReachability == Certain])
            <> " certain / "
            <> show (length [() | step <- manifest.emSteps, step.psReachability == Conditional])
            <> " conditional"
        )
      putStrLn ("    sends      " <> show manifest.emMaxSends)
      putStrLn ("    plan hash  " <> T.unpack (T.take 16 manifest.emPlanHash))
  putStrLn
    ( "    tokens     "
        <> show row.rowTokens
        <> occupancy
    )
  putStrLn ("    tree cost  " <> show row.rowTreeCost)
  putStrLn ("    holes      " <> show row.rowHoles <> " (expected further elaborations)")
  for_ row.rowFixture.fxNote $ \note -> putStrLn ("    note       " <> T.unpack note)
  where
    mark = if agrees row then "ok  " else "MISS"
    expected
      | agrees row = ""
      | otherwise = "  (fixture expected " <> T.unpack row.rowFixture.fxExpect <> ")"
    occupancy = case row.rowFixture.fxBaselineTokens of
      Nothing -> ""
      Just baseline ->
        "  vs "
          <> show baseline
          <> " horizon-1 baseline ("
          <> show (percent row.rowTokens baseline)
          <> "%)"

percent :: Int -> Int -> Int
percent _ 0 = 0
percent value baseline = (value * 100) `div` baseline

summarize :: [Row] -> IO ()
summarize rows = do
  putStrLn "── exit gate ─────────────────────────────────────────"
  stat "fixtures" (show total)
  stat "parse rate" (rate parsed)
  stat "validation rate" (rate admitted <> " of all, " <> rateOf admitted parsed <> " of parsed")
  stat "expectation agreement" (rate (length (filter agrees rows)))
  stat "context occupancy" occupancyLine
  stat "total tree cost" (show (sum (map (.rowTreeCost) rows)))
  stat "expected deoptimizations" (show deopts <> " (" <> show holes <> " holes + " <> show refused <> " refusals)")
  where
    total = length rows
    parsed = length [() | row <- rows, not (isUnparsed row.rowOutcome)]
    admitted = length [() | row <- rows, Admitted {} <- [row.rowOutcome]]
    refused = length [() | row <- rows, Refused {} <- [row.rowOutcome]]
    holes = sum (map (.rowHoles) rows)
    deopts = holes + refused

    isUnparsed = \case
      Unparsed _ -> True
      _ -> False

    rate n = rateOf n total
    rateOf _ 0 = "n/a"
    rateOf n outOf = show n <> "/" <> show outOf <> " (" <> show (percent n outOf) <> "%)"

    -- Only fixtures that recorded a baseline can say anything about occupancy;
    -- averaging over the rest would invent a denominator.
    measured = [(row.rowTokens, baseline) | row <- rows, Just baseline <- [row.rowFixture.fxBaselineTokens]]
    occupancyLine
      | null measured = "n/a (no fixture recorded a horizon-1 baseline)"
      | otherwise =
          show (sum (map fst measured))
            <> " vs "
            <> show (sum (map snd measured))
            <> " baseline tokens ("
            <> show (percent (sum (map fst measured)) (sum (map snd measured)))
            <> "%) over "
            <> show (length measured)
            <> " fixtures"

    stat label value = putStrLn ("  " <> pad label <> value)
    pad label = label <> replicate (max 1 (26 - length label)) ' '

oneLine :: Text -> Text
oneLine = T.take 160 . T.unwords . T.words
