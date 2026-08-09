-- | The structural type language a Plan is declared in.
--
-- ADR 002 is explicit that the IR "must not collapse every binding to an
-- unchecked JSON @Value@".  Runtime values /are/ JSON — tool results arrive
-- that way and inventing a parallel value universe would buy nothing — so the
-- separation lives here instead: a value is a 'Data.Aeson.Value', and its
-- declared type is a 'PlanSchema' that the validator checks statically and the
-- evaluator can re-check at any boundary.
--
-- Two deliberate absences shape the vocabulary:
--
--   * __There is no @SchemaAny@.__  One wildcard constructor would let every
--     binding in a generated plan typecheck, which is exactly the collapse the
--     ADR forbids.  Symbolic interpretation still needs an unknown value, but
--     that is a property of an interpreter's state, not a type a plan may
--     declare.
--   * __Objects are closed.__  An unknown field is a rejection, not a
--     tolerated extra.  The plan's author is a language model, and a field the
--     kernel cannot see the type of is a channel it cannot price.
module Max.Plan.Schema
  ( PlanSchema (..),
    SchemaField (..),
    SchemaError (..),
    schemaErrorText,
    renderSchema,
    checkValue,
    nullable,
    projectField,
    projectIndex,
    schemaFromJson,
  )
where

import Data.Aeson
  ( FromJSON (..),
    ToJSON (..),
    Value (..),
    object,
    withObject,
    (.:),
    (.=),
  )
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Foldable (traverse_)
import Data.List (sortOn)
import Data.Scientific (isInteger)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V

data PlanSchema
  = SchemaText
  | SchemaInt
  | SchemaNumber
  | SchemaBool
  | -- | A closed string vocabulary.  Empty is legal but uninhabited, and the
    -- validator treats a binding of that type as dead rather than as a wildcard.
    SchemaEnum ![Text]
  | SchemaArray !PlanSchema
  | SchemaObject ![SchemaField]
  | -- | Admits @null@ in addition to the inner type.  Produced by projecting an
    -- optional field, so absence propagates into the type instead of into a
    -- runtime surprise.
    SchemaNullable !PlanSchema
  deriving stock (Show, Eq)

data SchemaField = SchemaField
  { sfName :: !Text,
    sfSchema :: !PlanSchema,
    sfRequired :: !Bool
  }
  deriving stock (Show, Eq)

-- | Where a value stopped matching, and what was wanted there.  The path is
-- outermost first and empty at the root.
data SchemaError = SchemaError
  { schPath :: ![Text],
    schExpected :: !Text,
    schActual :: !Text
  }
  deriving stock (Show, Eq)

schemaErrorText :: SchemaError -> Text
schemaErrorText err =
  location <> ": expected " <> err.schExpected <> ", got " <> err.schActual
  where
    location = case err.schPath of
      [] -> "value"
      steps -> T.concat steps

-- | A compact one-line spelling, for error text and model-facing prose.
renderSchema :: PlanSchema -> Text
renderSchema = \case
  SchemaText -> "text"
  SchemaInt -> "int"
  SchemaNumber -> "number"
  SchemaBool -> "bool"
  SchemaEnum options -> "enum(" <> T.intercalate "|" options <> ")"
  SchemaArray element -> "[" <> renderSchema element <> "]"
  SchemaObject fields ->
    "{" <> T.intercalate ", " (map renderField fields) <> "}"
  SchemaNullable inner -> renderSchema inner <> "?"
  where
    renderField field =
      field.sfName
        <> (if field.sfRequired then "" else "?")
        <> ": "
        <> renderSchema field.sfSchema

-- | Wrap without stacking: @text??@ and @text?@ admit the same values, and a
-- normalized spelling keeps schema equality usable as a typecheck.
nullable :: PlanSchema -> PlanSchema
nullable = \case
  already@(SchemaNullable _) -> already
  inner -> SchemaNullable inner

checkValue :: PlanSchema -> Value -> Either SchemaError ()
checkValue = go []
  where
    go path schema value = case schema of
      SchemaText -> case value of
        String _ -> Right ()
        _ -> mismatch path "text" value
      SchemaInt -> case value of
        Number number | isInteger number -> Right ()
        _ -> mismatch path "int" value
      SchemaNumber -> case value of
        Number _ -> Right ()
        _ -> mismatch path "number" value
      SchemaBool -> case value of
        Bool _ -> Right ()
        _ -> mismatch path "bool" value
      SchemaEnum options -> case value of
        String text | text `elem` options -> Right ()
        _ -> mismatch path (renderSchema (SchemaEnum options)) value
      SchemaNullable inner -> case value of
        Null -> Right ()
        _ -> go path inner value
      SchemaArray element -> case value of
        Array items ->
          traverse_
            (\(index, item) -> go (path <> ["[" <> tshow index <> "]"]) element item)
            (zip [0 :: Int ..] (V.toList items))
        _ -> mismatch path "array" value
      SchemaObject fields -> case value of
        Object members -> do
          traverse_ (checkField path members) fields
          case unknown fields members of
            [] -> Right ()
            extra ->
              Left
                SchemaError
                  { schPath = path,
                    schExpected = "only the declared fields",
                    schActual = "unknown " <> T.intercalate ", " extra
                  }
        _ -> mismatch path "object" value

    checkField path members field =
      case KeyMap.lookup (Key.fromText field.sfName) members of
        Just Null | not field.sfRequired -> Right ()
        Just present -> go (path <> ["." <> field.sfName]) field.sfSchema present
        Nothing
          | field.sfRequired ->
              Left
                SchemaError
                  { schPath = path <> ["." <> field.sfName],
                    schExpected = renderSchema field.sfSchema,
                    schActual = "absent"
                  }
          | otherwise -> Right ()

    unknown fields members =
      [ Key.toText key
        | key <- KeyMap.keys members,
          Key.toText key `notElem` map (.sfName) fields
      ]

    mismatch path expected value =
      Left
        SchemaError
          { schPath = path,
            schExpected = expected,
            schActual = describe value
          }

describe :: Value -> Text
describe = \case
  String _ -> "text"
  Number number -> if isInteger number then "int" else "number"
  Bool _ -> "bool"
  Null -> "null"
  Array _ -> "array"
  Object _ -> "object"

-- | The type of @expr.field@.  Projecting an optional field yields a nullable
-- type rather than the bare inner one: the field may genuinely be missing, and
-- pretending otherwise would let a plan bind absence to a required input.
--
-- Projection through a nullable source propagates the nullability instead of
-- failing.  Without that, @hits[0].title@ — the single most obvious thing a
-- plan wants to write — could never typecheck, since 'projectIndex' is
-- necessarily nullable.  Null-propagation keeps it expressible while still
-- forcing the plan to eliminate the null before the value can satisfy a
-- non-nullable expectation.
projectField :: Text -> PlanSchema -> Either SchemaError PlanSchema
projectField name = \case
  SchemaObject fields -> case filter ((== name) . (.sfName)) fields of
    field : _
      | field.sfRequired -> Right field.sfSchema
      | otherwise -> Right (nullable field.sfSchema)
    [] ->
      Left
        SchemaError
          { schPath = ["." <> name],
            schExpected = "a declared field",
            schActual = "no such field"
          }
  SchemaNullable inner -> nullable <$> projectField name inner
  other ->
    Left
      SchemaError
        { schPath = ["." <> name],
          schExpected = "object",
          schActual = renderSchema other
        }

-- | The type of @expr[i]@.  Always nullable: the index is checked against a
-- length no static schema carries.
projectIndex :: PlanSchema -> Either SchemaError PlanSchema
projectIndex = \case
  SchemaArray element -> Right (nullable element)
  SchemaNullable inner -> nullable <$> projectIndex inner
  other ->
    Left
      SchemaError
        { schPath = ["[]"],
          schExpected = "array",
          schActual = renderSchema other
        }

-- | Read a hand-written tool schema (see "Max.Tools.Schema") as a 'PlanSchema'.
--
-- The tool catalog stays the source of truth for what a tool accepts; this is
-- the bridge that lets the validator check a plan's arguments against it today,
-- before ADR 002 step 2 gives the catalog first-class result schemas.  It is a
-- narrow reader on purpose — every JSON-Schema construct the kernel cannot
-- reason about is a rejection, so a tool whose schema outgrows this vocabulary
-- becomes un-plannable rather than silently unchecked.
schemaFromJson :: Value -> Either Text PlanSchema
schemaFromJson = go
  where
    go = \case
      Object members -> do
        traverse_ (refuseKey members) combinators
        case KeyMap.lookup "type" members of
          Nothing -> Left "schema without a \"type\""
          Just (String "string") -> case KeyMap.lookup "enum" members of
            Nothing -> Right SchemaText
            Just (Array options) -> SchemaEnum <$> traverse asText (V.toList options)
            Just _ -> Left "\"enum\" is not an array"
          Just (String "integer") -> Right SchemaInt
          Just (String "number") -> Right SchemaNumber
          Just (String "boolean") -> Right SchemaBool
          Just (String "array") -> case KeyMap.lookup "items" members of
            Just items -> SchemaArray <$> go items
            Nothing -> Left "array schema without \"items\""
          Just (String "object") -> do
            required <- case KeyMap.lookup "required" members of
              Nothing -> Right []
              Just (Array names) -> traverse asText (V.toList names)
              Just _ -> Left "\"required\" is not an array"
            let properties = case KeyMap.lookup "properties" members of
                  Just (Object declared) -> KeyMap.toList declared
                  _ -> []
            fields <- traverse (field required) (sortOn fst properties)
            pure (SchemaObject fields)
          Just (String other) -> Left ("unsupported schema type \"" <> other <> "\"")
          Just _ -> Left "\"type\" is not a string"
      _ -> Left "schema is not an object"

    field required (key, declared) = do
      inner <- go declared
      let name = Key.toText key
      pure SchemaField {sfName = name, sfSchema = inner, sfRequired = name `elem` required}

    asText = \case
      String text -> Right text
      _ -> Left "expected a string"

    -- Composition keywords describe a value the kernel would have to reason
    -- about by case analysis it does not implement.  Refuse rather than ignore.
    combinators = ["oneOf", "anyOf", "allOf", "not", "$ref"]
    refuseKey members key
      | KeyMap.member key members = Left ("unsupported schema keyword \"" <> Key.toText key <> "\"")
      | otherwise = Right ()

instance ToJSON PlanSchema where
  toJSON = \case
    SchemaText -> tagged "text" []
    SchemaInt -> tagged "int" []
    SchemaNumber -> tagged "number" []
    SchemaBool -> tagged "bool" []
    SchemaEnum options -> tagged "enum" ["values" .= options]
    SchemaArray element -> tagged "array" ["items" .= element]
    SchemaObject fields -> tagged "object" ["fields" .= fields]
    SchemaNullable inner -> tagged "nullable" ["inner" .= inner]
    where
      tagged name rest = object (("t" .= (name :: Text)) : rest)

instance FromJSON PlanSchema where
  parseJSON = withObject "PlanSchema" $ \o -> do
    tag <- o .: "t"
    case tag :: Text of
      "text" -> pure SchemaText
      "int" -> pure SchemaInt
      "number" -> pure SchemaNumber
      "bool" -> pure SchemaBool
      "enum" -> SchemaEnum <$> o .: "values"
      "array" -> SchemaArray <$> o .: "items"
      "object" -> SchemaObject <$> o .: "fields"
      "nullable" -> SchemaNullable <$> o .: "inner"
      other -> fail ("unknown schema tag " <> T.unpack other)

instance ToJSON SchemaField where
  toJSON field =
    object
      [ "name" .= field.sfName,
        "schema" .= field.sfSchema,
        "required" .= field.sfRequired
      ]

instance FromJSON SchemaField where
  parseJSON = withObject "SchemaField" $ \o ->
    SchemaField <$> o .: "name" <*> o .: "schema" <*> o .: "required"

tshow :: Show a => a -> Text
tshow = T.pack . show
