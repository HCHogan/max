module Max.Plan.ParseSpec (spec) where

import Control.Exception (evaluate)
import Data.Either (isLeft)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Max.Effects.Tools (SchemaVersion (..), ToolRef (..))
import Max.Effects.Tools qualified as Tools
import Max.Plan.Parse
import Max.Plan.Schema (PlanSchema (..))
import Max.Plan.Types
import Test.Hspec

-- The shape a real elaboration takes: search, branch on the result, answer or
-- hand the hard case back as a bounded hole.
program :: Text
program =
  T.unlines
    [ "let hits = search_web@3({ query: \"prime agent\" })",
      "if length(hits) > 0 {",
      "  done hits[0].title ?? \"没有结果\"",
      "} else {",
      "  hole \"找不到结果时该怎么回答\" : text",
      "    budget { calls: 1, sends: 1, fanout: 8, tokens: 2000, ms: 10000 }",
      "    effects { read(conversation), send(conversation) }",
      "    authority { conversation }",
      "    declassify { external }",
      "    accept { answers-question@1 }",
      "}"
    ]

parsed :: Plan
parsed = case parsePlan program of
  Right plan -> plan
  Left failure -> error (T.unpack (parseFailureText failure))

expr :: Text -> Either ParseFailure Expr
expr = parseExpr

spec :: Spec
spec = do
  describe "plans" $ do
    it "parses a call, a guard, a result and a hole into one plan" $
      case parsed of
        Call call (Guard _ (Done _) (Hole _)) -> do
          call.cnBind `shouldBe` Binder "hits"
          call.cnTool `shouldBe` ToolRef "search_web"
          call.cnSchemaVersion `shouldBe` SchemaVersion 3
        other -> expectationFailure ("unexpected plan shape: " <> show other)

    it "reads every declaration on the hole" $
      case parsed of
        Call _ (Guard _ _ (Hole goal)) -> do
          goal.goalObjective `shouldBe` "找不到结果时该怎么回答"
          goal.goalExpected `shouldBe` SchemaText
          goal.goalBudget.ebMaxCalls `shouldBe` 1
          goal.goalBudget.ebMaxFanout `shouldBe` 8
          goal.goalBudget.ebEffects
            `shouldBe` Set.fromList [EffRead CurrentConversation, EffSend AudienceConversation]
          goal.goalAuthority `shouldBe` Set.singleton Tools.CurrentConversation
          goal.goalDeclassify `shouldBe` Taint (Set.singleton TaintExternal)
          goal.goalAcceptance `shouldBe` [VerifierRef {verName = "answers-question", verVersion = 1}]
        other -> expectationFailure ("unexpected plan shape: " <> show other)

    it "defaults an omitted declaration to nothing, so it fails closed" $
      case parsePlan "hole \"随便\" : text" of
        Right (Hole goal) -> do
          goal.goalBudget `shouldBe` emptyBudget
          goal.goalAuthority `shouldBe` Set.empty
          goal.goalDeclassify `shouldBe` untainted
          goal.goalAcceptance `shouldBe` []
        other -> expectationFailure ("unexpected parse: " <> show other)

    it "refuses a repeated declaration block instead of letting the last one win" $
      parsePlan "hole \"x\" : text budget { calls: 1 } budget { calls: 9 }"
        `shouldSatisfy` isLeft

  describe "whole-input parse-or-reject" $ do
    it "refuses trailing input after an otherwise complete plan" $
      parsePlan "done \"ok\" and then some" `shouldSatisfy` isLeft

    it "refuses an unclosed guard rather than returning the part it read" $
      parsePlan "if true { done \"a\" } else { done \"b\"" `shouldSatisfy` isLeft

    it "refuses a construct that is not in the IR" $ do
      parsePlan "exec(\"rm -rf /\")" `shouldSatisfy` isLeft
      parsePlan "let x = tool@1({}) while true { done x }" `shouldSatisfy` isLeft

    it "refuses a grammar word as a binder" $ do
      parsePlan "let done = tool@1({}) done done" `shouldSatisfy` isLeft
      parsePlan "let map = tool@1({}) done map" `shouldSatisfy` isLeft

    it "refuses source past the length cap without parsing it" $ do
      let huge = T.replicate (maxSourceBytes + 1) "x"
      parsePlan huge `shouldBe` Left (SourceTooLong maxSourceBytes (maxSourceBytes + 1))

    it "refuses a tree past the nesting cap" $ do
      let deep = T.replicate (maxNestingDepth + 2) "[" <> T.replicate (maxNestingDepth + 2) "]"
      parsePlan ("done " <> deep) `shouldBe` Left (TooDeeplyNested maxNestingDepth)

  describe "expressions" $ do
    it "reads a handle as syntax, and a bare integer never as one" $ do
      expr "t#3:r2" `shouldBe` Right (EHandle "t#3:r2")
      expr "32" `shouldBe` Right (ELit (LitInt 32))
      expr "t#3" `shouldSatisfy` isLeft

    it "chains projections left to right" $
      expr "hit.results[0].title"
        `shouldBe` Right (EField (EIndex (EField (EVar (Binder "hit")) "results") 0) "title")

    it "keeps a grammar word usable as a field name" $
      expr "row.text" `shouldBe` Right (EField (EVar (Binder "row")) "text")

    it "separates an int literal from a number literal" $ do
      expr "1" `shouldBe` Right (ELit (LitInt 1))
      expr "1.0" `shouldBe` Right (ELit (LitNumber 1.0))
      expr "-2" `shouldBe` Right (ELit (LitInt (-2)))

    it "nests coalesce to the right" $
      expr "a ?? b ?? c"
        `shouldBe` Right (ECoalesce (EVar (Binder "a")) (ECoalesce (EVar (Binder "b")) (EVar (Binder "c"))))

    it "reads the bounded combinators" $ do
      expr "map(x in xs => x.id)"
        `shouldBe` Right (EMap (Binder "x") (EVar (Binder "xs")) (EField (EVar (Binder "x")) "id"))
      expr "filter(x in xs => x.n > 1)"
        `shouldBe` Right
          (EFilter (Binder "x") (EVar (Binder "xs")) (PCompare OpGt (EField (EVar (Binder "x")) "n") (ELit (LitInt 1))))
      expr "take(3, xs)" `shouldBe` Right (ETake 3 (EVar (Binder "xs")))
      expr "concat(\"a\", b)" `shouldBe` Right (EConcat [ELit (LitText "a"), EVar (Binder "b")])

  describe "predicates" $ do
    it "binds and tighter than or" $
      parsePlan "if a == 1 and b == 2 or c == 3 { done \"x\" } else { done \"y\" }"
        `shouldSatisfy` \case
          Right (Guard (POr [PAnd [_, _], _]) _ _) -> True
          _ -> False

    it "reads every comparison operator" $ do
      let cmp source = case parsePlan ("if " <> source <> " { done \"x\" } else { done \"y\" }") of
            Right (Guard (PCompare op _ _) _ _) -> Just op
            _ -> Nothing
      map cmp ["a == b", "a != b", "a < b", "a <= b", "a > b", "a >= b"]
        `shouldBe` map Just [OpEq, OpNe, OpLt, OpLe, OpGt, OpGe]
      map cmp ["a contains b", "a startswith b", "a endswith b"]
        `shouldBe` map Just [OpContains, OpPrefix, OpSuffix]

    it "accepts a literal condition but never a bare value as one" $ do
      parsePlan "if true { done \"x\" } else { done \"y\" }"
        `shouldSatisfy` \case
          Right (Guard (PBool True) _ _) -> True
          _ -> False
      -- A name is not a condition: a language that coerced one would let a
      -- typo silently decide a branch.
      parsePlan "if hits { done \"x\" } else { done \"y\" }" `shouldSatisfy` isLeft

  describe "totality on malformed input" $ do
    it "answers every prefix of a valid program without diverging" $
      mapM_ settles [T.take n program | n <- [0 .. T.length program]]

    it "answers every single-character deletion without diverging" $
      mapM_ settles [T.take n program <> T.drop (n + 1) program | n <- [0 .. T.length program - 1]]

    it "answers a corpus of hostile fragments without diverging" $
      mapM_
        settles
        [ "",
          "{",
          "}}}}}}",
          "let",
          "let x =",
          "done",
          "hole",
          "hole \"\" :",
          "if",
          "map(x in",
          "\"unterminated",
          "t#",
          "t#0:r",
          "@@@@",
          "let x = t@0({}) done x",
          T.replicate 500 "if true { ",
          T.replicate 500 "((((",
          T.replicate 200 "?? "
        ]

-- | The parser answered — with a plan or a failure — and forcing that answer
-- terminates.  The type already rules out a /partial/ plan; what this rules out
-- is a parser that loops or bottoms on input a model can produce.
settles :: Text -> Expectation
settles source = do
  forced <- evaluate (length (show (parsePlan source)))
  forced `shouldSatisfy` (> 0)
