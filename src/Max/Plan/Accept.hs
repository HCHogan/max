-- | Acceptance: the step between "the plan produced a value" and "the goal is
-- done".
--
-- ADR 002 is blunt about this — @Done@ produces a /candidate/ result, not proof
-- the objective was met. A goal completes only when the value matches its
-- expected schema __and__ its host-resolved acceptance verifiers pass. Every
-- other outcome re-holes the goal, and a re-holed goal is an ordinary hole
-- again: the same elaboration path, now carrying an account of what went wrong.
--
-- The failure modes are deliberately not collapsed. A verifier that was
-- unavailable, stale, or whose outcome is unknown did not pass; treating any of
-- them as a pass would let a broken gate certify anything, which is worse than
-- having no gate at all because it looks like one.
--
-- Note what this is /not/. A failed verifier is an invalid postcondition and
-- deoptimizes, while @Guard False@ is a valid predicate selecting the plan's
-- other branch. Routing the first through the second would turn "this answer is
-- wrong" into "take the else branch", which is a different claim entirely.
--
-- Re-holing is also where the loop is closed. Each attempt increments
-- 'goalAttempt', and 'maxAttempts' bounds it — so a goal whose verifier can
-- never be satisfied exhausts and suspends instead of elaborating forever.
-- Because the counter lives on the goal, a fork or a restart carries it along
-- rather than silently resetting the fuel.
module Max.Plan.Accept
  ( Verdict (..),
    verdictText,
    Acceptance (..),
    acceptGoal,
    maxEvidenceChars,
    maxAttempts,
  )
where

import Data.Aeson (Value)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Max.Plan.Schema (checkValue, schemaErrorText)
import Max.Plan.Types

-- | What a host-registered verifier reported.
data Verdict
  = Passed
  | -- | Ran, and said no.  The text is its bounded output.
    Failed !Text
  | -- | Not registered, or the registry could not produce it.
    Unavailable
  | -- | Registered, but its dependency fingerprint moved since it last ran.
    Stale !Text
  | -- | Started and did not finish: timeout, crash, cancelled.
    OutcomeUnknown !Text
  deriving stock (Show, Eq)

verdictText :: Verdict -> Text
verdictText = \case
  Passed -> "passed"
  Failed detail -> "failed: " <> detail
  Unavailable -> "unavailable"
  Stale detail -> "stale: " <> detail
  OutcomeUnknown detail -> "outcome unknown: " <> detail

data Acceptance
  = -- | Value and gates both satisfied.
    Accepted
  | -- | Try again, with this goal.
    Rehole !Goal
  | -- | Attempt fuel spent.  The goal is carried so the host can suspend and
    -- report it; it is emphatically not a completion.
    Exhausted !Goal
  deriving stock (Show, Eq)

-- | Ceiling on any single piece of evidence.  Verifier output can quote
-- attacker-controlled content, so it is truncated before it ever reaches a
-- prompt.
maxEvidenceChars :: Int
maxEvidenceChars = 512

-- | How many elaboration attempts one goal gets before it exhausts.
maxAttempts :: Int
maxAttempts = 3

-- | Decide whether a candidate value completes its goal.
--
-- The scope and taint of the candidate are passed in and inherited by any
-- evidence produced, because evidence /describes/ that value: a note about a
-- privately scoped result is itself privately scoped.
acceptGoal ::
  -- | Scope the candidate value was produced under.
  ResourceScope ->
  -- | Taint the candidate value carries.
  Taint ->
  Goal ->
  Value ->
  -- | Verdicts by verifier name.  A verifier the goal names but this map omits
  -- counts as 'Unavailable' — silence is not consent.
  Map Text Verdict ->
  Acceptance
acceptGoal scope taint goal candidate verdicts =
  case shapeEvidence <> gateEvidence of
    [] -> Accepted
    problems -> rehole problems
  where
    shapeEvidence = case checkValue goal.goalExpected candidate of
      Right () -> []
      Left err -> [evidenceOf FromResultSchema (schemaErrorText err)]

    -- Only reached when the shape is right: a verifier's opinion about a value
    -- of the wrong type is noise, and reporting both would bury the one fact
    -- that explains the other.
    gateEvidence
      | not (null shapeEvidence) = []
      | otherwise =
          [ evidenceOf (FromVerifier ref.verName) (verdictText verdict)
            | ref <- goal.goalAcceptance,
              let verdict = Map.findWithDefault Unavailable ref.verName verdicts,
              verdict /= Passed
          ]

    evidenceOf source detail =
      Evidence
        { evSource = source,
          evDetail = truncateTo maxEvidenceChars detail,
          evTaint = taint,
          evScope = scope
        }

    -- Evidence is replaced, not accumulated: the previous attempt's account is
    -- already reflected in this one, and an unbounded history would grow the
    -- elaboration prompt on every retry.
    rehole problems =
      let next = goal {goalEvidence = problems, goalAttempt = goal.goalAttempt + 1}
       in if next.goalAttempt >= maxAttempts then Exhausted next else Rehole next

truncateTo :: Int -> Text -> Text
truncateTo limit text
  | T.length text <= limit = text
  | otherwise = T.take limit text <> "…"
