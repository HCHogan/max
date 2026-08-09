module Max.Plan.EvalSpec (spec) where

import Data.Aeson (Value (..), object, (.=))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Vector qualified as V
import Max.Plan.Eval
import Max.Plan.Types
import Test.Hspec

numbers :: Int -> Value
numbers n = Array (V.fromList [Number (fromIntegral k) | k <- [1 .. n]])

env :: EvalEnv
env =
  EvalEnv
    { eeBindings =
        Map.fromList
          [ (Binder "xs", numbers 4),
            (Binder "hit", object ["title" .= ("prime" :: Text), "score" .= (7 :: Int)]),
            (Binder "text", String "hello world")
          ],
      eeHandles = Map.fromList [("t#1:r1", String "archived")],
      eeFanout = 8
    }

run :: Expr -> Either EvalError Value
run = evalExpr env defaultCostCeiling

holds :: Predicate -> Either EvalError Bool
holds = evalPredicate env defaultCostCeiling

spec :: Spec
spec = do
  describe "expressions" $ do
    it "evaluates literals and constructors" $ do
      run (ELit (LitText "hi")) `shouldBe` Right (String "hi")
      run (EArray [ELit (LitInt 1), ELit LitNull]) `shouldBe` Right (Array (V.fromList [Number 1, Null]))
      run (EObject [("k", ELit (LitBool True))]) `shouldBe` Right (object ["k" .= True])

    it "projects a declared field" $
      run (EField (EVar (Binder "hit")) "title") `shouldBe` Right (String "prime")

    it "reads a missing key as null, matching its nullable type" $
      run (EField (EVar (Binder "hit")) "author") `shouldBe` Right Null

    it "refuses to project through a non-object" $
      run (EField (EVar (Binder "text")) "title")
        `shouldBe` Left (TypeMismatch "object" "text")

    it "propagates null through a projection, matching its type" $ do
      run (EField (EIndex (EVar (Binder "xs")) 99) "title") `shouldBe` Right Null
      run (EIndex (EField (EVar (Binder "hit")) "missing") 0) `shouldBe` Right Null

    it "reads an out-of-range index as null and a negative one as an error" $ do
      run (EIndex (EVar (Binder "xs")) 99) `shouldBe` Right Null
      run (EIndex (EVar (Binder "xs")) (-1)) `shouldBe` Left (BadBound (-1))

    it "concatenates text and refuses anything else" $ do
      run (EConcat [ELit (LitText "a"), ELit (LitText "b")]) `shouldBe` Right (String "ab")
      run (EConcat [ELit (LitText "a"), ELit (LitInt 1)])
        `shouldBe` Left (TypeMismatch "text" "number")

    it "measures arrays and text" $ do
      run (ELength (EVar (Binder "xs"))) `shouldBe` Right (Number 4)
      run (ELength (EVar (Binder "text"))) `shouldBe` Right (Number 11)

    it "maps and filters over a bounded collection" $ do
      run (EMap (Binder "x") (EVar (Binder "xs")) (EVar (Binder "x")))
        `shouldBe` Right (numbers 4)
      run (EFilter (Binder "x") (EVar (Binder "xs")) (PCompare OpGt (EVar (Binder "x")) (ELit (LitInt 2))))
        `shouldBe` Right (Array (V.fromList [Number 3, Number 4]))

    it "takes a static prefix" $
      run (ETake 2 (EVar (Binder "xs"))) `shouldBe` Right (Array (V.fromList [Number 1, Number 2]))

    it "falls back only when the primary is null" $ do
      run (ECoalesce (ELit LitNull) (ELit (LitText "fallback"))) `shouldBe` Right (String "fallback")
      run (ECoalesce (ELit (LitText "primary")) (ELit (LitText "fallback")))
        `shouldBe` Right (String "primary")

    it "takes exactly one branch of a conditional" $ do
      run (EIf (PBool True) (ELit (LitInt 1)) (EVar (Binder "missing"))) `shouldBe` Right (Number 1)
      run (EIf (PBool False) (EVar (Binder "missing")) (ELit (LitInt 2))) `shouldBe` Right (Number 2)

  describe "predicates" $ do
    it "compares numbers and text but refuses mixed operands" $ do
      holds (PCompare OpLt (ELit (LitInt 1)) (ELit (LitInt 2))) `shouldBe` Right True
      holds (PCompare OpGe (ELit (LitText "b")) (ELit (LitText "a"))) `shouldBe` Right True
      holds (PCompare OpLt (ELit (LitInt 1)) (ELit (LitText "a")))
        `shouldBe` Left (TypeMismatch "two numbers or two texts" "number and text")

    it "tests containment in text and in arrays" $ do
      holds (PCompare OpContains (EVar (Binder "text")) (ELit (LitText "world"))) `shouldBe` Right True
      holds (PCompare OpContains (EVar (Binder "xs")) (ELit (LitInt 3))) `shouldBe` Right True
      holds (PCompare OpPrefix (EVar (Binder "text")) (ELit (LitText "hello"))) `shouldBe` Right True

    it "detects null" $ do
      holds (PIsNull (EField (EVar (Binder "hit")) "author")) `shouldBe` Right True
      holds (PIsNull (EField (EVar (Binder "hit")) "title")) `shouldBe` Right False

    it "short-circuits conjunction and disjunction" $ do
      -- The unbound variable would fail if the second operand were reached.
      holds (PAnd [PBool False, PIsNull (EVar (Binder "missing"))]) `shouldBe` Right False
      holds (POr [PBool True, PIsNull (EVar (Binder "missing"))]) `shouldBe` Right True

    it "quantifies over a bounded collection" $ do
      holds (PAll (Binder "x") (EVar (Binder "xs")) (PCompare OpGt (EVar (Binder "x")) (ELit (LitInt 0))))
        `shouldBe` Right True
      holds (PAny (Binder "x") (EVar (Binder "xs")) (PCompare OpGt (EVar (Binder "x")) (ELit (LitInt 3))))
        `shouldBe` Right True

  describe "totality" $ do
    it "refuses a collection past the fanout cap instead of truncating it" $ do
      let wide = env {eeBindings = Map.insert (Binder "wide") (numbers 9) env.eeBindings}
      evalExpr wide defaultCostCeiling (EMap (Binder "x") (EVar (Binder "wide")) (EVar (Binder "x")))
        `shouldBe` Left (FanoutExceeded 8 9)

    it "runs out of fuel rather than running long" $
      evalExpr env 2 (EArray [ELit (LitInt 1), ELit (LitInt 2), ELit (LitInt 3)])
        `shouldBe` Left OutOfFuel

    it "treats an unresolved handle as an error, never as null" $ do
      run (EHandle "t#1:r1") `shouldBe` Right (String "archived")
      run (EHandle "t#9:r9") `shouldBe` Left (UnresolvedHandle "t#9:r9")

    it "treats an unbound variable as an error" $
      run (EVar (Binder "nope")) `shouldBe` Left (UnboundVariable (Binder "nope"))

  describe "static cost model" $ do
    it "bounds the fuel evaluation actually spends" $
      mapM_ costBoundsFuel costFixtures

    it "prices nested collection work multiplicatively" $ do
      let inner = EMap (Binder "y") (EVar (Binder "xs")) (EVar (Binder "y"))
          outer = EMap (Binder "x") (EVar (Binder "xs")) inner
      exprCost 256 outer `shouldSatisfy` (> exprCost 256 inner * 200)

    it "prices deep nesting out of the default ceiling" $ do
      let nest 0 = EVar (Binder "x")
          nest depth = EMap (Binder "x") (EVar (Binder "xs")) (nest (depth - 1 :: Int))
      exprCost defaultFanout (nest 3) `shouldSatisfy` (> fromIntegral defaultCostCeiling)

-- | The invariant the module header claims: an expression given exactly its own
-- static cost as fuel never exhausts it.
costBoundsFuel :: Expr -> Expectation
costBoundsFuel expr =
  case evalExpr env (fromInteger (exprCost env.eeFanout expr)) expr of
    Left OutOfFuel -> expectationFailure ("static cost underestimated: " <> show expr)
    _ -> pure ()

costFixtures :: [Expr]
costFixtures =
  [ ELit (LitInt 1),
    EVar (Binder "xs"),
    EField (EVar (Binder "hit")) "title",
    EArray [ELit (LitInt 1), ELit (LitInt 2), ELit (LitInt 3)],
    EObject [("a", ELit (LitInt 1)), ("b", EVar (Binder "text"))],
    EConcat [ELit (LitText "a"), EVar (Binder "text")],
    ELength (EVar (Binder "xs")),
    ETake 2 (EVar (Binder "xs")),
    EMap (Binder "x") (EVar (Binder "xs")) (EConcat [ELit (LitText "n="), ELit (LitText "?")]),
    EFilter (Binder "x") (EVar (Binder "xs")) (PCompare OpGt (EVar (Binder "x")) (ELit (LitInt 1))),
    EIf (PAny (Binder "x") (EVar (Binder "xs")) (PBool True)) (ELit (LitInt 1)) (ELit (LitInt 2)),
    ECoalesce (EField (EVar (Binder "hit")) "author") (ELit (LitText "anon"))
  ]
