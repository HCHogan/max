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
-- emphatically not evidence that a model can produce admissible plans.
--
-- For that evidence, see @max-plan-live@, which asks real models the same
-- questions and judges their answers in this same environment.
--
-- It also cannot measure answer quality, because nothing here produces an
-- answer; the hole count is a structural proxy and is labelled as one.
module Main (main) where

import Data.Aeson (FromJSON (..), eitherDecodeStrict', withObject, (.:), (.:?))
import Data.ByteString.Char8 qualified as BS8
import Data.Foldable (for_)
import Data.List (intercalate)
import Data.Maybe (listToMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Harness
import Max.Context (estimateMessagesTokens)
import Max.Effects.LLM (ChatMessage (..))
import Data.Text.IO qualified as TIO
import Max.Plan.Interpret (EffectManifest (..), PreviewStep (..), Reachability (..), previewPlan)
import Max.Plan.Parse (parseFailureText, parsePlan)
import Data.Map.Strict (Map)
import Max.Effects.Tools
  ( SchemaVersion (..),
    ToolAuthority (..),
    ToolDeadline (..),
    ToolDefinition (..),
    ToolParallelism (..),
    ToolRef (..),
    ToolRetryClass (..),
  )
import Max.Plan.Catalog (PlannableTool (..), planCatalog, plannableTools)
import Max.Plan.Prompt (childPrompt, frontPrompt, guidePlans, renderEffect)
import Max.Plan.Types (Goal, planChildren)
import Max.Plan.Validate (CatalogEntry, childEnv, rejectionText, validatePlan)
import Max.Tools.Plan (planValidationEnv)
import Max.Toolset (defaultToolDeadline)
import System.Environment (getArgs)
import System.Exit (exitFailure, exitSuccess)

-- | One candidate segment.  Either something a model wrote and we kept, or —
-- for the starter set — something hand-authored to pin one kernel behaviour.
-- The harness cannot tell the difference, so the provenance has to be
-- remembered when reading the rates.
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

data Row = Row
  { rowFixture :: !Fixture,
    rowJudged :: !Judged,
    -- | Estimated tokens the candidate surface occupies.
    rowTokens :: !Int
  }

evaluate :: Fixture -> Row
evaluate fixture =
  Row
    { rowFixture = fixture,
      rowJudged = judge fixture.fxSource,
      rowTokens = estimateMessagesTokens [MsgUser fixture.fxSource]
    }

main :: IO ()
main = do
  args <- getArgs
  case args of
    -- The bytes a model would be handed, printed from the same environment the
    -- fixtures are judged against.  Worth being able to read directly: this is
    -- the artifact under test as much as the kernel is.
    ["--prompt"] -> putStrLn (T.unpack (frontPrompt planEnv))
    -- The other half of the same artifact: what a fork child is handed once
    -- 'childEnv' has taken away everything the goal did not ask for.  Built
    -- from a subgoal the guide itself shows, so this cannot drift into
    -- printing a prompt no example would ever produce.
    -- What production actually hands a model that calls @plan_guide@, as
    -- opposed to the harness environment the fixtures are judged against.  The
    -- two differ in the way that matters most — the fixture catalog is generous
    -- and the real plannable set is two tools — so being able to read the real
    -- one is what keeps the fixtures from measuring a world that does not
    -- exist.
    ["--production-guide", objective] ->
      putStrLn . T.unpack . frontPrompt . planValidationEnv productionPlanCatalog $ T.pack objective
    -- Judge one candidate against the production plannable catalog rather than
    -- the fixture one.  The difference is the whole point: a plan can be
    -- admissible in the harness and inadmissible in the world.
    ["--production-check", path] -> do
      source <- TIO.readFile path
      let env = planValidationEnv productionPlanCatalog "production check"
      case parsePlan source of
        Left failure -> putStrLn ("unparsed: " <> T.unpack (parseFailureText failure)) >> exitFailure
        Right parsed -> case validatePlan env "plan:check" parsed of
          Left rejection -> putStrLn ("refused: " <> T.unpack (rejectionText rejection)) >> exitFailure
          Right valid -> do
            let manifest = previewPlan env "plan:check" valid
            putStrLn ("admitted: " <> show manifest.emMaxCalls <> " calls, " <> show manifest.emMaxSends <> " sends, " <> show (length manifest.emHoles) <> " holes")
            exitSuccess
    ["--child-prompt"] -> case guideSubgoal of
      Nothing -> fail "no guide plan forks — nothing to render a child prompt from"
      Just child -> putStrLn (T.unpack (childPrompt (childEnv planEnv child)))
    _ -> runFixtures args

-- | The first subgoal any of the guide's worked examples dispatches.
guideSubgoal :: Maybe Goal
guideSubgoal =
  listToMaybe
    [ child
      | source <- guidePlans,
        Right plan <- [parsePlan source],
        (_, _, child) <- planChildren "turn:0:0" plan
    ]

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
agrees row = outcomeLabel row.rowJudged.jOutcome == row.rowFixture.fxExpect

report :: Row -> IO ()
report row = do
  putStrLn (mark <> " " <> T.unpack row.rowFixture.fxName)
  putStrLn ("    outcome    " <> T.unpack (outcomeLabel outcome) <> expected)
  case outcome of
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
    _ -> putStrLn ("    reason     " <> T.unpack (oneLine (outcomeDetail outcome)))
  putStrLn
    ( "    tokens     "
        <> show row.rowTokens
        <> occupancy
    )
  putStrLn ("    tree cost  " <> show row.rowJudged.jTreeCost)
  putStrLn ("    holes      " <> show row.rowJudged.jHoles <> " (expected further elaborations)")
  for_ row.rowFixture.fxNote $ \note -> putStrLn ("    note       " <> T.unpack note)
  where
    outcome = row.rowJudged.jOutcome
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
  stat "total tree cost" (show (sum [row.rowJudged.jTreeCost | row <- rows]))
  stat "expected deoptimizations" (show deopts <> " (" <> show holes <> " holes + " <> show refused <> " refusals)")
  where
    total = length rows
    parsed = length [() | row <- rows, not (isUnparsed row.rowJudged.jOutcome)]
    admitted = length [() | row <- rows, Admitted {} <- [row.rowJudged.jOutcome]]
    refused = length [() | row <- rows, Refused {} <- [row.rowJudged.jOutcome]]
    holes = sum [row.rowJudged.jHoles | row <- rows]
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
oneLine = T.take 160

-- | The plannable catalog as a live dispatch with search configured would see
-- it.  Definitions come from the real inventory rather than being invented
-- here, so a tool that gets gated off or renamed shows up as an absence.
productionPlanCatalog :: Map ToolRef CatalogEntry
productionPlanCatalog =
  planCatalog
    [ definition ref
      | ref <- map (.ptRef) plannableTools
    ]
  where
    definition ref =
      ToolDefinition
        { tdRef = ref,
          tdSchemaVersion = SchemaVersion 1,
          tdEffects = Set.empty,
          tdDeadline = ToolDeadline 120,
          tdParallelism = SequentialOnly,
          tdRetryClass = RetrySafe,
          tdAuthorities = Set.singleton CurrentConversation,
          -- What the real inventory gives a tool that doesn't override it;
          -- plan validation never reads it.
          tdDeadline = defaultToolDeadline,
          tdFailuresPrecedeEffects = False
        }
