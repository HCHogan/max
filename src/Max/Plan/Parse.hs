-- | The restricted pseudo-code surface a model writes an elaboration in.
--
-- ADR 002 separates the executable form from the authoring form and fixes only
-- the first.  This is the second: a small dialect that admits exactly the
-- constructs of "Max.Plan.Types" and nothing else.
--
-- The contract is whole-input parse-or-reject.  'parsePlan' returns a complete
-- 'Plan' or a failure; there is no partial parse, no recovery, and no looser
-- fallback interpreter to fall back to.  That matters more here than in an
-- ordinary language: the input is untrusted generation, and a parser that
-- salvaged "most" of a malformed plan would be inventing intent — deciding, on
-- a model's behalf, what it probably meant to do with real effects.  A failed
-- parse is an ordinary elaboration failure that deoptimizes the turn.
--
-- Two limits sit in front of the grammar rather than inside it:
--
--   * 'maxSourceBytes' bounds the input before parsing begins, which bounds
--     recursion depth by construction — a megabyte of open brackets cannot
--     reach the parser at all.
--   * 'maxNestingDepth' bounds the tree afterwards, so a deeply nested but
--     short input is rejected before anything walks it.
--
-- Neither is a semantic rule.  They exist so that the parser is total on
-- adversarial input, which the validator downstream is entitled to assume.
module Max.Plan.Parse
  ( parsePlan,
    parseExpr,
    ParseFailure (..),
    parseFailureText,
    maxSourceBytes,
    maxNestingDepth,
    planDepth,
  )
where

import Data.Maybe (isNothing)
import Data.Scientific (fromFloatDigits)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Void (Void)
import Max.Effects.Tools (SchemaVersion (..), ToolRef (..))
import Max.Effects.Tools qualified as Tools
import Max.Plan.Schema (PlanSchema (..), SchemaField (..), nullable)
import Max.Plan.Types
import Text.Megaparsec
import Text.Megaparsec.Char
import Text.Megaparsec.Char.Lexer qualified as L

-- | Input longer than this is refused unparsed.  Generous for a plan segment
-- and small enough that recursion depth cannot run away.
maxSourceBytes :: Int
maxSourceBytes = 32768

-- | Structural depth ceiling for the parsed tree.
maxNestingDepth :: Int
maxNestingDepth = 32

data ParseFailure
  = -- | Limit, then the actual length.
    SourceTooLong !Int !Int
  | -- | Limit; the offending depth is not reported because a tree this deep is
    -- not worth describing back to its author.
    TooDeeplyNested !Int
  | Syntax !Text
  deriving stock (Show, Eq)

parseFailureText :: ParseFailure -> Text
parseFailureText = \case
  SourceTooLong limit actual ->
    "plan source is " <> tshow actual <> " bytes, limit is " <> tshow limit
  TooDeeplyNested limit -> "plan nests deeper than " <> tshow limit
  Syntax detail -> detail

type P = Parsec Void Text

parsePlan :: Text -> Either ParseFailure Plan
parsePlan = whole planP planDepth

parseExpr :: Text -> Either ParseFailure Expr
parseExpr = whole exprP exprDepth

whole :: P a -> (a -> Int) -> Text -> Either ParseFailure a
whole parser depth source
  | T.length source > maxSourceBytes = Left (SourceTooLong maxSourceBytes (T.length source))
  | otherwise = case runParser (spaceConsumer *> parser <* eof) "plan" source of
      Left bundle -> Left (Syntax (T.pack (errorBundlePretty bundle)))
      Right parsed
        | depth parsed > maxNestingDepth -> Left (TooDeeplyNested maxNestingDepth)
        | otherwise -> Right parsed

-- Lexing.  No comment syntax: a generated dialect has no one to explain itself
-- to, and every character that is not the plan is a character that can hide one.

spaceConsumer :: P ()
spaceConsumer = L.space space1 empty empty

lexeme :: P a -> P a
lexeme = L.lexeme spaceConsumer

symbol :: Text -> P Text
symbol = L.symbol spaceConsumer

parens, braces, brackets :: P a -> P a
parens = between (symbol "(") (symbol ")")
braces = between (symbol "{") (symbol "}")
brackets = between (symbol "[") (symbol "]")

commaSep :: P a -> P [a]
commaSep parser = parser `sepBy` symbol ","

-- | Words that may not be used as a binder or a tool name.  Field names are
-- exempt: a field called @text@ is unambiguous in field position, and refusing
-- it would make ordinary tool schemas unwritable.
reservedWords :: [Text]
reservedWords =
  [ "let", "done", "if", "then", "else", "hole", "in",
    "true", "false", "null",
    "not", "and", "or", "all", "any", "isnull",
    "contains", "startswith", "endswith",
    "map", "filter", "concat", "length", "take",
    "budget", "effects", "authority", "declassify", "accept",
    "text", "int", "number", "bool", "enum",
    "read", "write", "send", "llm", "reflect",
    "conversation", "sender", "endpoint", "sandbox", "process", "external",
    "private"
  ]

keyword :: Text -> P ()
keyword word = lexeme (try (() <$ string word <* notFollowedBy identChar))

identChar :: P Char
identChar = alphaNumChar <|> char '_'

-- | An unrestricted name, for positions where no keyword could appear.
fieldName :: P Text
fieldName = lexeme (try (T.pack <$> ((:) <$> (letterChar <|> char '_') <*> many identChar)))

-- | A name that must not collide with the grammar's vocabulary.
identifier :: P Text
identifier = try $ do
  name <- fieldName
  if name `elem` reservedWords
    then fail ("reserved word " <> T.unpack name <> " cannot be used as a name")
    else pure name

stringLiteral :: P Text
stringLiteral = lexeme (T.pack <$> (char '"' *> manyTill L.charLiteral (char '"')))

-- | A result handle in exactly ADR 004's grammar.  Parsed as one token so a
-- bare integer can never become one.
handleLiteral :: P Text
handleLiteral = lexeme . try $ do
  _ <- string "t#"
  turn <- L.decimal
  _ <- string ":r"
  step <- L.decimal
  pure ("t#" <> tshow (turn :: Int) <> ":r" <> tshow (step :: Int))

integer :: P Int
integer = lexeme (L.signed (pure ()) L.decimal)

-- Plans.

planP :: P Plan
planP =
  choice
    [ callP,
      keyword "done" *> (Done <$> exprP),
      guardP,
      keyword "hole" *> (Hole <$> goalP)
    ]

callP :: P Plan
callP = do
  keyword "let"
  name <- identifier
  _ <- symbol "="
  tool <- identifier
  _ <- symbol "@"
  version <- lexeme L.decimal
  input <- parens exprP
  continuation <- planP
  pure
    ( Call
        CallNode
          { cnBind = Binder name,
            cnTool = ToolRef tool,
            cnSchemaVersion = SchemaVersion version,
            cnInput = input
          }
        continuation
    )

guardP :: P Plan
guardP = do
  keyword "if"
  condition <- predicateP
  consequent <- braces planP
  keyword "else"
  alternative <- braces planP
  pure (Guard condition consequent alternative)

-- Goals.

-- | One declaration block inside a hole.  Parsed as a list and folded, so a
-- repeated block is a rejection rather than a silent last-one-wins.
data GoalBlock
  = BudgetBlock !Int !Int !Int !Int !Int
  | EffectsBlock ![PlanEffect]
  | AuthorityBlock ![Tools.ToolAuthority]
  | DeclassifyBlock ![TaintLabel]
  | AcceptBlock ![VerifierRef]

goalP :: P Goal
goalP = do
  objective <- stringLiteral
  _ <- symbol ":"
  expectedSchema <- schemaP
  blocks <- many goalBlockP
  let base =
        Goal
          { goalObjective = objective,
            goalExpected = expectedSchema,
            goalAcceptance = [],
            goalBudget = emptyBudget,
            goalAuthority = Set.empty,
            goalDeclassify = untainted,
            goalDeps = noDependencies
          }
  either fail pure (foldGoalBlocks base blocks)

-- | Every block defaults to nothing rather than to something permissive, so an
-- omitted declaration fails closed at the validator.
foldGoalBlocks :: Goal -> [GoalBlock] -> Either String Goal
foldGoalBlocks = go Set.empty
  where
    go _ goal [] = Right goal
    go seen goal (block : rest) = do
      let name = blockName block
      if Set.member name seen
        then Left ("duplicate " <> T.unpack name <> " block")
        else go (Set.insert name seen) (apply goal block) rest

    apply goal = \case
      BudgetBlock calls sends fanout tokenCap ms ->
        goal
          { goalBudget =
              goal.goalBudget
                { ebMaxCalls = calls,
                  ebMaxSends = sends,
                  ebMaxFanout = fanout,
                  ebMaxTokens = tokenCap,
                  ebMaxWallClockMs = ms
                }
          }
      EffectsBlock effects ->
        goal {goalBudget = goal.goalBudget {ebEffects = Set.fromList effects}}
      AuthorityBlock authorities -> goal {goalAuthority = Set.fromList authorities}
      DeclassifyBlock labels -> goal {goalDeclassify = Taint (Set.fromList labels)}
      AcceptBlock verifiers -> goal {goalAcceptance = verifiers}

    blockName = \case
      BudgetBlock {} -> "budget"
      EffectsBlock {} -> "effects"
      AuthorityBlock {} -> "authority"
      DeclassifyBlock {} -> "declassify"
      AcceptBlock {} -> "accept"

goalBlockP :: P GoalBlock
goalBlockP =
  choice
    [ keyword "budget" *> braces budgetFields,
      keyword "effects" *> (EffectsBlock <$> braces (commaSep effectP)),
      keyword "authority" *> (AuthorityBlock <$> braces (commaSep authorityP)),
      keyword "declassify" *> (DeclassifyBlock <$> braces (commaSep taintP)),
      keyword "accept" *> (AcceptBlock <$> braces (commaSep verifierP))
    ]

budgetFields :: P GoalBlock
budgetFields = do
  fields <- commaSep ((,) <$> fieldName <*> (symbol ":" *> integer))
  let pick name = maybe 0 id (lookup name fields)
  pure (BudgetBlock (pick "calls") (pick "sends") (pick "fanout") (pick "tokens") (pick "ms"))

effectP :: P PlanEffect
effectP =
  choice
    [ keyword "read" *> (EffRead <$> parens scopeP),
      keyword "write" *> (EffWrite <$> parens scopeP),
      keyword "send" *> (EffSend <$> parens audienceP),
      EffLLM <$ keyword "llm",
      keyword "reflect" *> (EffReflect <$> parens stringLiteral)
    ]

scopeP :: P ResourceScope
scopeP =
  choice
    [ CurrentConversation <$ keyword "conversation",
      keyword "sandbox" *> (SandboxScope <$> stringLiteral),
      keyword "process" *> (ProcessScope <$> stringLiteral),
      keyword "external" *> (ExternalScope <$> stringLiteral)
    ]

audienceP :: P Audience
audienceP =
  choice
    [ AudienceConversation <$ keyword "conversation",
      AudienceSender <$ keyword "sender"
    ]

authorityP :: P Tools.ToolAuthority
authorityP =
  choice
    [ Tools.CurrentConversation <$ keyword "conversation",
      Tools.CurrentEndpoint <$ keyword "endpoint",
      keyword "process" *> (Tools.ProcessResource <$> parens stringLiteral)
    ]

taintP :: P TaintLabel
taintP =
  choice
    [ TaintExternal <$ keyword "external",
      TaintPrivate <$ keyword "private"
    ]

verifierP :: P VerifierRef
verifierP = do
  name <- verifierName
  _ <- symbol "@"
  version <- lexeme L.decimal
  pure VerifierRef {verName = name, verVersion = version}

-- | Verifier names may contain hyphens.  Unambiguous because the expression
-- language has no arithmetic: a @-@ appears only inside a number literal.
verifierName :: P Text
verifierName = lexeme (try (T.pack <$> ((:) <$> letterChar <*> many (identChar <|> char '-'))))

-- Schemas.

schemaP :: P PlanSchema
schemaP = do
  base <- schemaAtomP
  marks <- many (symbol "?")
  pure (foldl (\schema _ -> nullable schema) base marks)

schemaAtomP :: P PlanSchema
schemaAtomP =
  choice
    [ SchemaText <$ keyword "text",
      SchemaInt <$ keyword "int",
      SchemaNumber <$ keyword "number",
      SchemaBool <$ keyword "bool",
      keyword "enum" *> (SchemaEnum <$> parens (commaSep stringLiteral)),
      SchemaArray <$> brackets schemaP,
      SchemaObject <$> braces (commaSep schemaFieldP)
    ]

schemaFieldP :: P SchemaField
schemaFieldP = do
  name <- fieldName
  optionalMark <- optional (symbol "?")
  _ <- symbol ":"
  schema <- schemaP
  pure SchemaField {sfName = name, sfSchema = schema, sfRequired = isNothing optionalMark}

-- Expressions.

exprP :: P Expr
exprP = do
  primary <- postfixP
  fallbacks <- many (symbol "??" *> postfixP)
  pure (foldr1 ECoalesce (primary : fallbacks))

postfixP :: P Expr
postfixP = do
  base <- atomP
  foldl (flip ($)) base <$> many suffix
  where
    suffix =
      choice
        [ flip EField <$> (symbol "." *> fieldName),
          flip EIndex <$> brackets integer
        ]

atomP :: P Expr
atomP =
  choice
    [ ELit (LitBool True) <$ keyword "true",
      ELit (LitBool False) <$ keyword "false",
      ELit LitNull <$ keyword "null",
      ELit . LitText <$> stringLiteral,
      ELit <$> numberLiteral,
      EHandle <$> handleLiteral,
      keyword "concat" *> (EConcat <$> parens (commaSep exprP)),
      keyword "length" *> (ELength <$> parens exprP),
      keyword "take" *> parens (ETake <$> integer <*> (symbol "," *> exprP)),
      keyword "map" *> parens (comprehension EMap exprP),
      keyword "filter" *> parens (comprehension EFilter predicateP),
      ifExprP,
      EArray <$> brackets (commaSep exprP),
      EObject <$> braces (commaSep ((,) <$> fieldName <*> (symbol ":" *> exprP))),
      EVar . Binder <$> identifier,
      parens exprP
    ]
  where
    comprehension build body = do
      name <- identifier
      keyword "in"
      source <- exprP
      _ <- symbol "=>"
      build (Binder name) source <$> body

ifExprP :: P Expr
ifExprP = do
  keyword "if"
  condition <- predicateP
  keyword "then"
  consequent <- exprP
  keyword "else"
  EIf condition consequent <$> exprP

-- | @1@ is an int and @1.0@ is a number.  The distinction is syntactic rather
-- than value-based, so a plan's declared arithmetic type is what it wrote.
numberLiteral :: P PlanLit
numberLiteral =
  lexeme
    ( try (LitNumber . fromFloatDigits <$> L.signed (pure ()) (L.float :: P Double))
        <|> (LitInt <$> L.signed (pure ()) L.decimal)
    )

-- Predicates.

predicateP :: P Predicate
predicateP = do
  first <- conjunctionP
  rest <- many (keyword "or" *> conjunctionP)
  pure (if null rest then first else POr (first : rest))

conjunctionP :: P Predicate
conjunctionP = do
  first <- negationP
  rest <- many (keyword "and" *> negationP)
  pure (if null rest then first else PAnd (first : rest))

negationP :: P Predicate
negationP = (keyword "not" *> (PNot <$> negationP)) <|> atomPredicateP

atomPredicateP :: P Predicate
atomPredicateP =
  choice
    [ keyword "isnull" *> (PIsNull <$> parens exprP),
      keyword "all" *> parens (quantifier PAll),
      keyword "any" *> parens (quantifier PAny),
      try (parens predicateP),
      comparisonP
    ]
  where
    quantifier build = do
      name <- identifier
      keyword "in"
      source <- exprP
      _ <- symbol "=>"
      build (Binder name) source <$> predicateP

-- | A comparison, or a bare boolean literal.
--
-- Both start by parsing an expression, so the two are distinguished after the
-- fact rather than by lookahead: with an operator it is a comparison, without
-- one it is only a predicate if it was literally @true@ or @false@.  Anything
-- else — a bare name, a projection — is a rejection, because a language that
-- quietly coerced a value into a condition is one where a typo decides a branch.
comparisonP :: P Predicate
comparisonP = do
  left <- exprP
  operator <- optional compareOpP
  case operator of
    Just op -> PCompare op left <$> exprP
    Nothing -> case left of
      ELit (LitBool value) -> pure (PBool value)
      _ -> fail "expected a comparison operator"

compareOpP :: P CompareOp
compareOpP =
  choice
    [ OpEq <$ symbol "==",
      OpNe <$ symbol "!=",
      OpLe <$ try (symbol "<="),
      OpGe <$ try (symbol ">="),
      OpLt <$ symbol "<",
      OpGt <$ symbol ">",
      OpContains <$ keyword "contains",
      OpPrefix <$ keyword "startswith",
      OpSuffix <$ keyword "endswith"
    ]

-- Depth, for the post-parse ceiling.

planDepth :: Plan -> Int
planDepth = \case
  Done expr -> 1 + exprDepth expr
  Call call continuation -> 1 + max (exprDepth call.cnInput) (planDepth continuation)
  Guard condition consequent alternative ->
    1 + maximum [predicateDepth condition, planDepth consequent, planDepth alternative]
  Hole _ -> 1

exprDepth :: Expr -> Int
exprDepth = \case
  ELit _ -> 1
  EVar _ -> 1
  EHandle _ -> 1
  EField source _ -> 1 + exprDepth source
  EIndex source _ -> 1 + exprDepth source
  EArray items -> 1 + maximum0 (map exprDepth items)
  EObject fields -> 1 + maximum0 (map (exprDepth . snd) fields)
  EConcat parts -> 1 + maximum0 (map exprDepth parts)
  ELength source -> 1 + exprDepth source
  ETake _ source -> 1 + exprDepth source
  EMap _ source body -> 1 + max (exprDepth source) (exprDepth body)
  EFilter _ source keep -> 1 + max (exprDepth source) (predicateDepth keep)
  EIf condition consequent alternative ->
    1 + maximum [predicateDepth condition, exprDepth consequent, exprDepth alternative]
  ECoalesce primary fallback -> 1 + max (exprDepth primary) (exprDepth fallback)

predicateDepth :: Predicate -> Int
predicateDepth = \case
  PBool _ -> 1
  PNot inner -> 1 + predicateDepth inner
  PAnd parts -> 1 + maximum0 (map predicateDepth parts)
  POr parts -> 1 + maximum0 (map predicateDepth parts)
  PCompare _ left right -> 1 + max (exprDepth left) (exprDepth right)
  PIsNull source -> 1 + exprDepth source
  PAll _ source body -> 1 + max (exprDepth source) (predicateDepth body)
  PAny _ source body -> 1 + max (exprDepth source) (predicateDepth body)

maximum0 :: [Int] -> Int
maximum0 = foldr max 0

tshow :: Show a => a -> Text
tshow = T.pack . show
