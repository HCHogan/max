module Max.Plan.ParseSpec (spec) where

import Control.Exception (evaluate)
import Data.Either (isLeft, isRight)
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

    it "tells a tool call apart from a plain value after the same `let x =`" $ do
      -- Both forms start identically, so the tool form is tried with
      -- backtracking.  A regression here would silently reinterpret one as
      -- the other, which is the worst kind: it still parses.
      case parsePlan "let x = hits\ndone \"ok\"" of
        Right (Let binder (EVar source) (Done _)) -> do
          binder `shouldBe` Binder "x"
          source `shouldBe` Binder "hits"
        other -> expectationFailure ("expected a pure binding, got: " <> show other)
      case parsePlan "let x = hits@3({ q: \"y\" })\ndone \"ok\"" of
        Right (Call call (Done _)) -> call.cnTool `shouldBe` ToolRef "hits"
        other -> expectationFailure ("expected a call, got: " <> show other)

    it "binds an expression that looks nothing like a call" $
      case parsePlan "let n = length(hits)\nlet best = hits[0].title ?? \"\"\ndone best" of
        Right (Let _ (ELength _) (Let _ (ECoalesce _ _) (Done _))) -> pure ()
        other -> expectationFailure ("unexpected plan shape: " <> show other)

    it "still refuses a bare call with no name to bind it to" $
      -- Two models wrote this.  It stays a rejection: a plan reads top to
      -- bottom as a chain of named steps, and one anonymous step in the middle
      -- would be the only line whose result nothing can refer to.
      parsePlan "let hits = search_web@3({ query: \"q\" })\nreply@1({ text: \"hi\" })\ndone \"ok\""
        `shouldSatisfy` isLeft

    it "names a goal mid-plan and carries on" $
      -- Five of the six parse failures across every live run were this, from
      -- two of three models.  The third form of `let`, told apart by the same
      -- backtracking that separates a call from a value.
      case parsePlan "let 话题 = hole \"用户说的话题\" : text budget { calls: 0 }\nlet hits = search_web@3({ query: 话题 })\ndone \"ok\"" of
        Right (Bind binder goal (Call _ (Done _))) -> do
          binder `shouldBe` Binder "话题"
          goal.goalObjective `shouldBe` "用户说的话题"
          goal.goalExpected `shouldBe` SchemaText
          goal.goalBudget.ebMaxCalls `shouldBe` 0
        other -> expectationFailure ("expected a bind, got: " <> show other)

    it "still tells the three `let` forms apart" $ do
      let shapeOf source = case parsePlan (source <> "\ndone \"ok\"") of
            Right (Call {}) -> "call"
            Right (Bind {}) -> "bind"
            Right (Let {}) -> "let"
            other -> "unexpected: " <> T.pack (show other)
      map
        shapeOf
        [ "let x = t@1({ q: \"y\" })",
          "let x = hole \"什么\" : text",
          "let x = hits"
        ]
        `shouldBe` ["call", "bind", "let"]

    it "reads the bindings a goal asks to see" $
      case parsePlan "let 框架 = \"甲\"\nlet 住宿 = hole \"按框架找\" : text inputs { 框架 }\ndone 住宿" of
        Right (Let _ _ (Bind _ goal _)) -> goal.goalInputs `shouldBe` [Binder "框架"]
        other -> expectationFailure ("unexpected parse: " <> show other)

    it "reads a fork's subgoals, its policies and its continuation" $
      case parsePlan "fork {\n  a: hole \"查甲\" : text budget { calls: 1 }\n  b: hole \"查乙\" : text budget { calls: 1 }\n}\ndone concat(a, b)" of
        Right (Fork fork (Done _)) -> do
          map (fst) fork.fnChildren `shouldBe` [Binder "a", Binder "b"]
          map (\(_, goal) -> goal.goalObjective) fork.fnChildren `shouldBe` ["查甲", "查乙"]
          fork.fnJoin `shouldBe` JoinAll
          fork.fnWatch `shouldBe` WatchOnFailure
        other -> expectationFailure ("unexpected plan shape: " <> show other)

    it "defaults both policies to the quiet reading, and reads them when written" $ do
      let withPolicies suffix =
            parsePlan ("fork { a: hole \"x\" : text }" <> suffix <> "\ndone a")
      case withPolicies "" of
        Right (Fork fork _) -> (fork.fnJoin, fork.fnWatch) `shouldBe` (JoinAll, WatchOnFailure)
        other -> expectationFailure ("unexpected plan shape: " <> show other)
      case withPolicies " join all watch each" of
        Right (Fork fork _) -> (fork.fnJoin, fork.fnWatch) `shouldBe` (JoinAll, WatchEach)
        other -> expectationFailure ("unexpected plan shape: " <> show other)

    it "reads a subgoal list with or without commas between its entries" $
      -- Entries already end in a brace, so separators are noise; a model that
      -- writes them anyway is not wrong about anything, and refusing would be
      -- a rejection about punctuation.
      parsePlan "fork { a: hole \"x\" : text, b: hole \"y\" : text }\ndone concat(a, b)"
        `shouldBe` parsePlan "fork { a: hole \"x\" : text b: hole \"y\" : text }\ndone concat(a, b)"

    it "refuses a fork with no subgoals at the grammar, not only at the kernel" $
      parsePlan "fork { }\ndone \"ok\"" `shouldSatisfy` isLeft

    it "reads the handles a goal is handed, and never a bare number as one" $ do
      case parsePlan "hole \"x\" : text resources { t#3:r2, t#5:r1 }" of
        Right (Hole goal) -> goal.goalResources `shouldBe` ["t#3:r2", "t#5:r1"]
        other -> expectationFailure ("unexpected parse: " <> show other)
      parsePlan "hole \"x\" : text resources { 3 }" `shouldSatisfy` isLeft

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
          goal.goalAcceptance `shouldBe` [VerifierRef {verName = "answers-question", verVersion = 1}]
        other -> expectationFailure ("unexpected plan shape: " <> show other)

    it "defaults an omitted declaration to nothing, so it fails closed" $
      case parsePlan "hole \"随便\" : text" of
        Right (Hole goal) -> do
          goal.goalBudget `shouldBe` emptyBudget
          goal.goalAuthority `shouldBe` Set.empty
          goal.goalResources `shouldBe` []
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
      -- `map` is tried before a bare name in expression position, so a binder
      -- sharing it would fail where it is read rather than where it is bound.
      parsePlan "let map = tool@1({}) done map" `shouldSatisfy` isLeft

    it "allows a name that is only a keyword where no name can stand" $ do
      -- A live model lost an otherwise correct plan to `let text = "我在"`.
      -- Nothing but a type follows a hole's `:`, and nothing but an effect
      -- appears inside `effects { }`, so reserving those words bought nothing
      -- and cost the obvious names.
      case parsePlan "let text = \"我在\"\ndone text" of
        Right (Let binder _ (Done _)) -> binder `shouldBe` Binder "text"
        other -> expectationFailure ("expected a pure binding, got: " <> show other)
      mapM_
        (\name -> parsePlan ("let " <> name <> " = \"x\"\ndone " <> name) `shouldSatisfy` isRight)
        ["text", "int", "number", "bool", "budget", "effects", "accept", "read", "send", "conversation", "external", "each"]

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
          "fork",
          "fork {",
          "fork { a",
          "fork { a: }",
          "fork { a: hole } done a",
          "fork { a: hole \"x\" : text } join",
          "fork { a: hole \"x\" : text } watch",
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
