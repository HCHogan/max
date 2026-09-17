-- | Parse JSON schemas once and validate values against a closed, typed tree.
-- The original encoding is retained for provider requests and durable hashes.
module Max.Schema (Schema, SchemaDialect (..), parseSchema, schemaValue, validateSchemaValue, unconstrainedSchema) where

import Control.Monad (unless, when)
import Data.Aeson (FromJSON (..), Object, ToJSON (..), Value (..))
import Data.Aeson.Key qualified as Key (Key, fromText, toText)
import Data.Aeson.KeyMap qualified as KM
  ( KeyMap,
    empty,
    keys,
    lookup,
    member,
    toList,
  )
import Data.Foldable (toList, traverse_)
import Data.Maybe (fromMaybe, isNothing)
import Data.Scientific (Scientific, floatingOrInteger)
import Data.Text (Text)
import Data.Text qualified as T (length, pack, unpack)

-- Tools accept annotations, unspecified types and unions. Authored contracts
-- deliberately require a single type and explicit object openness.
data SchemaDialect = ToolSchema | WorkflowContract deriving stock (Eq, Show)

data Schema = Schema !Value !Shape !(Maybe [Value]) ![Schema]
  deriving stock (Eq, Show)

data Shape
  = AnyValue
  | ObjectValue !(KM.KeyMap Schema) ![Text] !Bool
  | ArrayValue !(Maybe Schema) !Bounds
  | StringValue !Bounds
  | NumberValue !Bool !Bounds
  | BooleanValue
  | NullValue
  | UnionValue ![Shape]
  | ApplicableValue ![Shape]
  deriving stock (Eq, Show)

data Bounds = Bounds !(Maybe Scientific) !(Maybe Scientific)
  deriving stock (Eq, Show)

instance ToJSON Schema where
  toJSON = schemaValue

instance FromJSON Schema where
  parseJSON value = either (fail . T.unpack) pure (parseSchema ToolSchema value)

schemaValue :: Schema -> Value
schemaValue (Schema original _ _ _) = original

unconstrainedSchema :: Schema
unconstrainedSchema = Schema (Object KM.empty) AnyValue Nothing []

parseSchema :: SchemaDialect -> Value -> Either Text Schema
parseSchema dialect = go 0
  where
    go :: Int -> Value -> Either Text Schema
    go depth original@(Object fields) = do
      when (depth > 16) (Left "schema nesting exceeds 16")
      kinds <- case KM.lookup "type" fields of
        Nothing | dialect == ToolSchema -> pure []
        Just (String kind) -> pure [kind]
        Just (Array values) | dialect == ToolSchema && not (null values) -> traverse text (toList values)
        _ -> Left "schema requires a supported type"
      let common = ["type", "description", "enum"]
          specific kind = case kind of
            "object" -> ["properties", "required", "additionalProperties"]
            "array" -> ["items", "minItems", "maxItems"]
            "string" -> ["minLength", "maxLength"]
            "number" -> ["minimum", "maximum"]
            "integer" -> ["minimum", "maximum"]
            _ -> []
          inferred = [kind | kind <- ["object", "array", "string", "number"], any (`KM.member` fields) (specific kind)]
          checkedKinds = if null kinds then inferred else kinds
          allowed = common <> concatMap specific checkedKinds
      -- Tool annotations do not affect validation. Unsupported constraints are
      -- rejected instead of being advertised and silently ignored.
      let toolKeys = ["default", "title", "examples", "anyOf"]
      traverse_ (\key -> unless (key `elem` allowed || (dialect == ToolSchema && key `elem` toolKeys)) (Left ("unsupported schema keyword: " <> Key.toText key))) (KM.keys fields)
      case KM.lookup "description" fields of
        Nothing -> pure ()
        Just (String _) -> pure ()
        _ -> Left "description must be a string"
      shapes <- traverse (shape depth fields) checkedKinds
      let base
            | null kinds = if null shapes then AnyValue else ApplicableValue shapes
            | otherwise = case shapes of [] -> AnyValue; [one] -> one; many -> UnionValue many
      alternatives <- case KM.lookup "anyOf" fields of
        Nothing -> pure []
        Just (Array values) | not (null values) -> traverse (go (depth + 1)) (toList values)
        _ -> Left "anyOf must be a nonempty array"
      enumeration <- case KM.lookup "enum" fields of
        Nothing -> pure Nothing
        Just (Array values) | not (null values) -> do
          let candidate = Schema original base Nothing alternatives
          traverse_ (validateSchemaValue candidate) values
          pure (Just (toList values))
        _ -> Left "enum must be a nonempty array"
      pure (Schema original base enumeration alternatives)
    go _ _ = Left "schema must be an object"
    shape depth fields = \case
      "object" -> do
        props <- case KM.lookup "properties" fields of
          Nothing -> pure KM.empty
          Just (Object values) -> traverse (go (depth + 1)) values
          _ -> Left "properties must be an object"
        needed <- case KM.lookup "required" fields of
          Nothing -> pure []
          Just (Array values) -> traverse text (toList values)
          _ -> Left "required must be an array"
        traverse_ (\name -> unless (KM.member (Key.fromText name) props) (Left "required property has no schema")) needed
        open <- case KM.lookup "additionalProperties" fields of
          Nothing | dialect == ToolSchema -> pure True
          Just (Bool value) -> pure value
          _ -> Left "object contracts require explicit additionalProperties boolean"
        pure (ObjectValue props needed open)
      "array" -> do
        item <- traverse (go (depth + 1)) (KM.lookup "items" fields)
        when (dialect == WorkflowContract && isNothing item) (Left "array contract requires items")
        ArrayValue item <$> bounds fields "minItems" "maxItems" True
      "string" -> StringValue <$> bounds fields "minLength" "maxLength" True
      "number" -> NumberValue False <$> bounds fields "minimum" "maximum" False
      "integer" -> NumberValue True <$> bounds fields "minimum" "maximum" False
      "boolean" -> pure BooleanValue
      "null" -> pure NullValue
      other -> Left ("unsupported schema type: " <> other)
    text (String value) = pure value
    text _ = Left "expected a string"

bounds :: Object -> Key.Key -> Key.Key -> Bool -> Either Text Bounds
bounds fields lo hi integral = do
  lower <- traverse bound (KM.lookup lo fields)
  upper <- traverse bound (KM.lookup hi fields)
  when (fromMaybe False ((>) <$> lower <*> upper)) (Left "schema bounds are reversed")
  pure (Bounds lower upper)
  where
    bound (Number n) | not integral || (n >= 0 && isInteger n) = pure n
    bound _ = Left "invalid schema bound"

validateSchemaValue :: Schema -> Value -> Either Text ()
validateSchemaValue = go "$"
  where
    go path (Schema _ shape enumeration alternatives) value = do
      check path shape value
      unless (null alternatives || any (succeeds . (\schema -> go path schema value)) alternatives) (bad path "value matches no anyOf alternative")
      unless (maybe True (value `elem`) enumeration) (bad path "value is outside enum")
    check path shape value = case (shape, value) of
      (AnyValue, _) -> pure ()
      (ApplicableValue shapes, _) -> traverse_ (\s -> when (applies s value) (check path s value)) shapes
      (UnionValue shapes, _) -> unless (any (succeeds . (\s -> check path s value)) shapes) (bad path "value has no permitted type")
      (ObjectValue props needed open, Object args) -> do
        traverse_ (\name -> unless (KM.member (Key.fromText name) args) (bad path ("missing required property: " <> name))) needed
        traverse_
          ( \(key, item) -> case KM.lookup key props of
              Just schema -> go (path <> "." <> Key.toText key) schema item
              Nothing -> unless open (bad path ("unknown property: " <> Key.toText key))
          )
          (KM.toList args)
      (ArrayValue item limits, Array values) -> do
        bounded path limits (fromIntegral (length values))
        traverse_ (\schema -> traverse_ (\(i, itemValue) -> go (path <> "[" <> T.pack (show i) <> "]") schema itemValue) (zip [0 :: Int ..] (toList values))) item
      (StringValue limits, String valueText) -> bounded path limits (fromIntegral (T.length valueText))
      (NumberValue integral limits, Number n) | not integral || isInteger n -> bounded path limits n
      (BooleanValue, Bool _) -> pure ()
      (NullValue, Null) -> pure ()
      _ -> bad path "value has the wrong type"
    applies ObjectValue {} Object {} = True
    applies ArrayValue {} Array {} = True
    applies StringValue {} String {} = True
    applies NumberValue {} Number {} = True
    applies _ _ = False
    bounded path (Bounds lo hi) n = do
      when (maybe False (n <) lo) (bad path "value is below minimum")
      when (maybe False (n >) hi) (bad path "value is above maximum")
    bad path detail = Left (path <> ": " <> detail)
    succeeds = either (const False) (const True)

isInteger :: Scientific -> Bool
isInteger n = case floatingOrInteger @Double @Integer n of
  Right _ -> True
  Left _ -> False
