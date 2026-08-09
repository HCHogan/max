module Max.Plan.AcceptSpec (spec) where

import Data.Aeson (Value (..))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Max.Plan.Accept
import Max.Plan.Schema (PlanSchema (..))
import Max.Plan.Types
import Test.Hspec

goal :: Goal
goal =
  Goal
    { goalObjective = "回答用户的问题",
      goalExpected = SchemaText,
      goalAcceptance = [VerifierRef {verName = "answers-question", verVersion = 1}],
      goalBudget = emptyBudget,
      goalAuthority = Set.empty,
      goalDeclassify = Taint (Set.singleton TaintExternal),
      goalDeps = noDependencies,
      goalEvidence = [],
      goalAttempt = 0
    }

external :: Taint
external = Taint (Set.singleton TaintExternal)

accept :: Goal -> Value -> [(T.Text, Verdict)] -> Acceptance
accept g value verdicts =
  acceptGoal (ExternalScope "web") external g value (Map.fromList verdicts)

reholed :: Acceptance -> Maybe Goal
reholed = \case
  Rehole g -> Just g
  _ -> Nothing

spec :: Spec
spec = do
  describe "acceptance" $ do
    it "accepts a value that matches the shape and passes its gate" $
      accept goal (String "答案") [("answers-question", Passed)] `shouldBe` Accepted

    it "accepts a goal with no gates once the shape matches" $
      accept goal {goalAcceptance = []} (String "答案") [] `shouldBe` Accepted

    it "re-holes on a shape mismatch, with the mismatch as evidence" $ do
      let evidence = maybe [] (.goalEvidence) (reholed (accept goal (Number 1) []))
      map (.evSource) evidence `shouldBe` [FromResultSchema]
      map (.evDetail) evidence `shouldBe` ["value: expected text, got int"]

    it "does not report gate opinions about a value of the wrong type" $ do
      let evidence = maybe [] (.goalEvidence) (reholed (accept goal (Number 1) [("answers-question", Failed "no")]))
      length evidence `shouldBe` 1

    it "re-holes on a failed gate, carrying its bounded output" $ do
      let evidence = maybe [] (.goalEvidence) (reholed (accept goal (String "答案") [("answers-question", Failed "没有回答问题")]))
      map (.evSource) evidence `shouldBe` [FromVerifier "answers-question"]
      map (.evDetail) evidence `shouldBe` ["failed: 没有回答问题"]

  describe "a broken gate is not a passing gate" $ do
    it "refuses to complete when a named verifier reported nothing at all" $
      accept goal (String "答案") [] `shouldSatisfy` (/= Accepted)

    it "refuses to complete on unavailable, stale, or unknown outcomes" $ do
      let verdicts = [Unavailable, Stale "fingerprint moved", OutcomeUnknown "timeout"]
      map (\verdict -> accept goal (String "答案") [("answers-question", verdict)]) verdicts
        `shouldSatisfy` all (/= Accepted)

    it "says which way the gate broke" $
      map (.evDetail) (maybe [] (.goalEvidence) (reholed (accept goal (String "答案") [("answers-question", Stale "moved")])))
        `shouldBe` ["stale: moved"]

  describe "evidence" $ do
    it "inherits the scope and taint of the value it describes" $ do
      let evidence = maybe [] (.goalEvidence) (reholed (accept goal (Number 1) []))
      map (.evScope) evidence `shouldBe` [ExternalScope "web"]
      map (.evTaint) evidence `shouldBe` [external]

    it "bounds verifier output, which can quote content an attacker wrote" $ do
      let flood = T.replicate (maxEvidenceChars * 3) "x"
          evidence = maybe [] (.goalEvidence) (reholed (accept goal (String "答案") [("answers-question", Failed flood)]))
      map (T.length . (.evDetail)) evidence `shouldBe` [maxEvidenceChars + 1]

    it "replaces the previous attempt's evidence instead of accumulating it" $ do
      let once = reholed (accept goal (Number 1) [])
          twice = once >>= \g -> reholed (accept g (Number 2) [])
      fmap (length . (.goalEvidence)) twice `shouldBe` Just 1

    it "reports every failing gate at once, since this is advice and not admission" $ do
      let twoGates =
            goal
              { goalAcceptance =
                  [ VerifierRef {verName = "answers-question", verVersion = 1},
                    VerifierRef {verName = "is-polite", verVersion = 1}
                  ]
              }
          evidence =
            maybe [] (.goalEvidence) $
              reholed (accept twoGates (String "答案") [("answers-question", Failed "no"), ("is-polite", Failed "rude")])
      map (.evSource) evidence
        `shouldBe` [FromVerifier "answers-question", FromVerifier "is-polite"]

  describe "attempt fuel" $ do
    it "counts each re-hole on the goal itself, so a fork carries it" $ do
      let once = reholed (accept goal (Number 1) [])
      fmap (.goalAttempt) once `shouldBe` Just 1

    it "exhausts rather than elaborating a hopeless goal forever" $ do
      let step g = case accept g (Number 1) [] of
            Rehole next -> Right next
            other -> Left other
          run 0 g = Right g
          run n g = step g >>= run (n - 1 :: Int)
      -- Two re-holes are allowed; the third attempt exhausts.
      case run 2 goal of
        Left other -> expectationFailure ("re-holing stopped early: " <> show other)
        Right twice -> case accept twice (Number 1) [] of
          Exhausted final -> do
            final.goalAttempt `shouldBe` maxAttempts
            final.goalEvidence `shouldSatisfy` (not . null)
          other -> expectationFailure ("expected exhaustion, got " <> show other)

    it "never turns an unfinished value into a success" $ do
      let exhausted = goal {goalAttempt = maxAttempts - 1}
      accept exhausted (Number 1) [] `shouldSatisfy` \case
        Exhausted _ -> True
        _ -> False
