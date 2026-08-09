-- | The total interpreter for ADR 002's 'Expr' and 'Predicate' languages.
--
-- "Total" here is a claim the module has to earn, not a property inherited from
-- the datatype.  It rests on three things:
--
--   * __Every recursion is structural.__  There is no application, no fixpoint,
--     and no name that resolves outside the environment, so evaluation always
--     descends into a strictly smaller expression.
--   * __Every collection is bounded.__  'EMap', 'EFilter', 'PAll' and 'PAny'
--     refuse a source longer than the fanout cap.  Refuse, not truncate: a
--     silently shortened list is a wrong answer, while a rejection is a
--     deoptimization the journal can see.
--   * __Fuel is spent per node.__  Even a plan that skipped validation cannot
--     spin, so the evaluator is safe to run on unvalidated input — which
--     matters, because preview and symbolic interpretation want to look at
--     candidate expressions before the kernel has blessed them.
--
-- The static cost model ('exprCost') and the runtime fuel are the same
-- quantity measured twice: 'exprCost' is an upper bound on the fuel evaluation
-- can spend, so an expression the validator admits under 'defaultCostCeiling'
-- can never exhaust 'defaultCostCeiling' fuel at run time.  "Max.Plan.EvalSpec"
-- holds that correspondence down.
module Max.Plan.Eval
  ( EvalEnv (..),
    EvalError (..),
    evalErrorText,
    evalExpr,
    evalPredicate,
    exprCost,
    predicateCost,
    defaultFanout,
    defaultCostCeiling,
  )
where

import Control.Monad (filterM, when)
import Data.Aeson (Value (..))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import Max.Plan.Types
  ( Binder (..),
    CompareOp (..),
    Expr (..),
    Predicate (..),
    litValue,
  )

-- | Largest collection a bounded combinator may traverse.  Chosen so that a
-- couple of nested maps still price under 'defaultCostCeiling' while a plan
-- that wants to iterate over real data has to say so as an explicit tool call.
defaultFanout :: Int
defaultFanout = 256

-- | The fuel an expression is given, and the static cost above which the
-- validator rejects one.  One number, deliberately: see the module header.
defaultCostCeiling :: Int
defaultCostCeiling = 100000

data EvalEnv = EvalEnv
  { -- | Call results and combinator elements currently in scope.
    eeBindings :: !(Map Binder Value),
    -- | Bodies of result handles the validator already resolved.  A handle
    -- absent here is an error rather than a null: an unresolved handle means
    -- the kernel never proved its scope, and quietly evaluating to null would
    -- turn that into a plausible-looking answer.
    eeHandles :: !(Map Text Value),
    eeFanout :: !Int
  }
  deriving stock (Show, Eq)

data EvalError
  = OutOfFuel
  | UnboundVariable !Binder
  | UnresolvedHandle !Text
  | -- | Cap, then the length that exceeded it.
    FanoutExceeded !Int !Int
  | -- | Expected, then what was found.
    TypeMismatch !Text !Text
  | BadBound !Int
  deriving stock (Show, Eq)

evalErrorText :: EvalError -> Text
evalErrorText = \case
  OutOfFuel -> "expression exceeded its evaluation fuel"
  UnboundVariable binder -> "unbound variable " <> binder.unBinder
  UnresolvedHandle handle -> "unresolved result handle " <> handle
  FanoutExceeded limit actual ->
    "collection of " <> tshow actual <> " exceeds the fanout cap of " <> tshow limit
  TypeMismatch expected actual -> "expected " <> expected <> ", got " <> actual
  BadBound bound -> "invalid bound " <> tshow bound

-- | Fuel-threading with short-circuit failure.  Hand-rolled rather than pulled
-- from @transformers@ so the totality argument stays readable in one file.
newtype Eval a = Eval {stepEval :: Int -> Either EvalError (a, Int)}

instance Functor Eval where
  fmap f (Eval run) = Eval (fmap (\(value, fuel) -> (f value, fuel)) . run)

instance Applicative Eval where
  pure value = Eval (\fuel -> Right (value, fuel))
  Eval runF <*> Eval runX = Eval $ \fuel -> do
    (f, afterF) <- runF fuel
    (x, afterX) <- runX afterF
    pure (f x, afterX)

instance Monad Eval where
  Eval run >>= f = Eval $ \fuel -> do
    (value, spent) <- run fuel
    stepEval (f value) spent

burn :: Eval ()
burn = Eval $ \fuel ->
  if fuel <= 0 then Left OutOfFuel else Right ((), fuel - 1)

abort :: EvalError -> Eval a
abort err = Eval (const (Left err))

evalExpr :: EvalEnv -> Int -> Expr -> Either EvalError Value
evalExpr env fuel expr = fst <$> stepEval (expression env expr) fuel

evalPredicate :: EvalEnv -> Int -> Predicate -> Either EvalError Bool
evalPredicate env fuel predicate = fst <$> stepEval (proposition env predicate) fuel

expression :: EvalEnv -> Expr -> Eval Value
expression env = go
  where
    go = \case
      ELit lit -> burn >> pure (litValue lit)
      EVar binder -> do
        burn
        case Map.lookup binder env.eeBindings of
          Just value -> pure value
          Nothing -> abort (UnboundVariable binder)
      EHandle handle -> do
        burn
        case Map.lookup handle env.eeHandles of
          Just value -> pure value
          Nothing -> abort (UnresolvedHandle handle)
      EField source name -> do
        burn
        go source >>= \case
          -- A missing key is null, matching the nullable type
          -- 'Max.Plan.Schema.projectField' assigns an optional field.  A
          -- misspelled key is the validator's job, not a runtime surprise.
          Object members -> pure (fromMaybe Null (KeyMap.lookup (Key.fromText name) members))
          -- Projection propagates null, matching the type projection assigns.
          Null -> pure Null
          other -> abort (TypeMismatch "object" (describe other))
      EIndex source index -> do
        burn
        when (index < 0) (abort (BadBound index))
        go source >>= \case
          Array items -> pure (fromMaybe Null (items V.!? index))
          Null -> pure Null
          other -> abort (TypeMismatch "array" (describe other))
      EArray items -> burn >> (Array . V.fromList <$> traverse go items)
      EObject fields -> do
        burn
        members <- traverse (\(name, value) -> (Key.fromText name,) <$> go value) fields
        pure (Object (KeyMap.fromList members))
      EConcat parts -> do
        burn
        pieces <- traverse (\part -> asText =<< go part) parts
        pure (String (T.concat pieces))
      ELength source -> do
        burn
        go source >>= \case
          Array items -> pure (Number (fromIntegral (V.length items)))
          String text -> pure (Number (fromIntegral (T.length text)))
          other -> abort (TypeMismatch "array or text" (describe other))
      ETake count source -> do
        burn
        when (count < 0) (abort (BadBound count))
        go source >>= \case
          Array items -> pure (Array (V.take count items))
          other -> abort (TypeMismatch "array" (describe other))
      EMap binder source body -> do
        burn
        items <- boundedItems env =<< go source
        Array . V.fromList <$> traverse (\item -> expression (bind env binder item) body) items
      EFilter binder source keep -> do
        burn
        items <- boundedItems env =<< go source
        kept <- filterM (\item -> proposition (bind env binder item) keep) items
        pure (Array (V.fromList kept))
      EIf condition consequent alternative -> do
        burn
        taken <- proposition env condition
        if taken then go consequent else go alternative
      ECoalesce primary fallback -> do
        burn
        go primary >>= \case
          Null -> go fallback
          value -> pure value

    asText = \case
      String text -> pure text
      other -> abort (TypeMismatch "text" (describe other))

proposition :: EvalEnv -> Predicate -> Eval Bool
proposition env = go
  where
    go = \case
      PBool value -> burn >> pure value
      PNot inner -> burn >> (not <$> go inner)
      -- Short-circuiting, so the cost model's sum over the parts stays an
      -- upper bound rather than an estimate.
      PAnd parts -> burn >> allM parts
      POr parts -> burn >> anyM parts
      PCompare op left right -> do
        burn
        compareValues op <$> expression env left <*> expression env right >>= either abort pure
      PIsNull source -> do
        burn
        (== Null) <$> expression env source
      PAll binder source body -> do
        burn
        items <- boundedItems env =<< expression env source
        allM' (\item -> proposition (bind env binder item) body) items
      PAny binder source body -> do
        burn
        items <- boundedItems env =<< expression env source
        anyM' (\item -> proposition (bind env binder item) body) items

    allM = allM' go
    anyM = anyM' go

compareValues :: CompareOp -> Value -> Value -> Either EvalError Bool
compareValues op left right = case op of
  OpEq -> Right (left == right)
  OpNe -> Right (left /= right)
  OpLt -> ordering (< EQ)
  OpLe -> ordering (/= GT)
  OpGt -> ordering (> EQ)
  OpGe -> ordering (/= LT)
  OpContains -> case (left, right) of
    (String haystack, String needle) -> Right (needle `T.isInfixOf` haystack)
    (Array items, needle) -> Right (needle `V.elem` items)
    _ -> mismatch "text or array"
  OpPrefix -> texts T.isPrefixOf
  OpSuffix -> texts T.isSuffixOf
  where
    ordering accept = case (left, right) of
      (Number a, Number b) -> Right (accept (compare a b))
      (String a, String b) -> Right (accept (compare a b))
      _ -> mismatch "two numbers or two texts"
    texts test = case (left, right) of
      (String haystack, String needle) -> Right (test needle haystack)
      _ -> mismatch "text"
    mismatch expected =
      Left (TypeMismatch expected (describe left <> " and " <> describe right))

-- | Enforce the fanout cap, refusing rather than truncating.
boundedItems :: EvalEnv -> Value -> Eval [Value]
boundedItems env = \case
  Array items
    | V.length items > env.eeFanout -> abort (FanoutExceeded env.eeFanout (V.length items))
    | otherwise -> pure (V.toList items)
  other -> abort (TypeMismatch "array" (describe other))

bind :: EvalEnv -> Binder -> Value -> EvalEnv
bind env binder value =
  env {eeBindings = Map.insert binder value env.eeBindings}

-- | An upper bound on the fuel 'evalExpr' can spend.
--
-- Bounded combinators price at the fanout cap because no static schema carries
-- a collection's length, so nesting multiplies and a plan that nests too deeply
-- prices itself out of 'defaultCostCeiling'.  That is the intended pressure:
-- iteration over real data belongs in a tool call whose effects the validator
-- can see, not in an expression.
exprCost :: Int -> Expr -> Integer
exprCost fanout = go
  where
    width = fromIntegral (max 0 fanout)
    go = \case
      ELit _ -> 1
      EVar _ -> 1
      EHandle _ -> 1
      EField source _ -> 1 + go source
      EIndex source _ -> 1 + go source
      EArray items -> 1 + sum (map go items)
      EObject fields -> 1 + sum (map (go . snd) fields)
      EConcat parts -> 1 + sum (map go parts)
      ELength source -> 1 + go source
      ETake _ source -> 1 + go source
      EMap _ source body -> 1 + go source + width * go body
      EFilter _ source keep -> 1 + go source + width * predicateCost fanout keep
      -- Only one branch runs, so the bound is the worse of the two.
      EIf condition consequent alternative ->
        1 + predicateCost fanout condition + max (go consequent) (go alternative)
      ECoalesce primary fallback -> 1 + go primary + go fallback

predicateCost :: Int -> Predicate -> Integer
predicateCost fanout = go
  where
    width = fromIntegral (max 0 fanout)
    go = \case
      PBool _ -> 1
      PNot inner -> 1 + go inner
      PAnd parts -> 1 + sum (map go parts)
      POr parts -> 1 + sum (map go parts)
      PCompare _ left right -> 1 + exprCost fanout left + exprCost fanout right
      PIsNull source -> 1 + exprCost fanout source
      PAll _ source body -> 1 + exprCost fanout source + width * go body
      PAny _ source body -> 1 + exprCost fanout source + width * go body

describe :: Value -> Text
describe = \case
  String _ -> "text"
  Number _ -> "number"
  Bool _ -> "bool"
  Null -> "null"
  Array _ -> "array"
  Object _ -> "object"

-- Base has no short-circuiting monadic @all@/@any@, and the cost model relies
-- on that short circuit to stay an upper bound, so they are written out here.

allM' :: (a -> Eval Bool) -> [a] -> Eval Bool
allM' test = foldr step (pure True)
  where
    step item rest = do
      holds <- test item
      if holds then rest else pure False

anyM' :: (a -> Eval Bool) -> [a] -> Eval Bool
anyM' test = foldr step (pure False)
  where
    step item rest = do
      holds <- test item
      if holds then pure True else rest

tshow :: Show a => a -> Text
tshow = T.pack . show
