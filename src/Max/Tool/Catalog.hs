-- | Validated, non-executable tool catalog and pure schema checks.
module Max.Tool.Catalog
  ( ToolCatalog,
    buildToolCatalog,
    catalogTools,
    catalogSpecs,
    lookupCatalogTool,
    validateArguments,
  )
where

import Crypto.Hash.SHA256 qualified as SHA256
import Data.Aeson (Object, Value (..), encode)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Lazy qualified as LBS
import Data.Foldable (foldlM, toList, traverse_)
import Data.List (find)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Scientific (floatingOrInteger)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Max.Tool.Types

newtype ToolCatalog = ToolCatalog (Map ToolRef CatalogTool)
  deriving stock (Show, Eq)

catalogTools :: ToolCatalog -> [CatalogTool]
catalogTools (ToolCatalog tools) = Map.elems tools

catalogSpecs :: ToolCatalog -> [ToolSpec]
catalogSpecs = map (\view -> ToolSpec view.ctDefinition.tdRef.unToolRef view.ctDescription view.ctSchema) . catalogTools

lookupCatalogTool :: ToolRef -> ToolCatalog -> Maybe CatalogTool
lookupCatalogTool ref (ToolCatalog tools) = Map.lookup ref tools

buildToolCatalog :: [ToolDefinition] -> [ToolSpec] -> Either ToolCatalogError ToolCatalog
buildToolCatalog definitions specs = do
  definitionsByRef <- uniqueDefinitions definitions
  specsByRef <- foldlM insertSpec Map.empty specs
  traverse_ (requireSpec specsByRef) (Map.keys definitionsByRef)
  traverse_ (requireDefinition definitionsByRef) (Map.keys specsByRef)
  ToolCatalog <$> Map.traverseWithKey (register specsByRef) definitionsByRef
  where
    insertSpec acc spec
      | Map.member (ToolRef spec.specName) acc = Left (DuplicateToolRunner (ToolRef spec.specName))
      | otherwise = Right (Map.insert (ToolRef spec.specName) spec acc)
    register specsByRef ref definition = do
      validateDefinition definition
      spec <- maybe (Left (MissingToolRunner ref)) Right (Map.lookup ref specsByRef)
      if T.null (T.strip spec.specDescription)
        then Left (EmptyToolDescription ref)
        else do
          validateSchema ref spec.specSchema
          pure (CatalogTool definition spec.specDescription spec.specSchema (schemaHash spec.specSchema))
    requireSpec specsByRef ref =
      if Map.member ref specsByRef then Right () else Left (MissingToolRunner ref)
    requireDefinition definitionsByRef ref =
      if Map.member ref definitionsByRef then Right () else Left (MissingToolDefinition ref)

uniqueDefinitions :: [ToolDefinition] -> Either ToolCatalogError (Map ToolRef ToolDefinition)
uniqueDefinitions = foldlM insertOne Map.empty
  where
    insertOne acc definition
      | Map.member definition.tdRef acc = Left (DuplicateToolDefinition definition.tdRef)
      | otherwise = Right (Map.insert definition.tdRef definition acc)

validateDefinition :: ToolDefinition -> Either ToolCatalogError ()
validateDefinition definition
  | T.null (T.strip definition.tdRef.unToolRef) = bad "tool ref is blank"
  | definition.tdSchemaVersion.unSchemaVersion <= 0 = bad "schema version must be positive"
  | definition.tdDeadline.toolDeadlineSeconds <= 0 = bad "start-to-close deadline must be positive"
  | definition.tdCallMode /= WorkCall && definition.tdParallelism == ParallelSafe =
      bad "execution checkpoint and finish calls must be sequential"
  | definition.tdParallelism == ParallelSafe && any isMutating definition.tdEffects =
      bad "mutating, sending, LLM, or reflective tools cannot declare ParallelSafe"
  | definition.tdRetryClass == RetrySafe && any isMutating definition.tdEffects =
      bad "mutating, sending, LLM, or reflective tools cannot declare RetrySafe"
  | otherwise = Right ()
  where
    bad = Left . InvalidToolMetadata definition.tdRef

isMutating :: ToolEffect -> Bool
isMutating EffectRead {} = False
isMutating _ = True

schemaHash :: Value -> SchemaHash
schemaHash =
  SchemaHash
    . TE.decodeUtf8
    . B16.encode
    . SHA256.hash
    . LBS.toStrict
    . encode

validateSchema :: ToolRef -> Value -> Either ToolCatalogError ()
validateSchema ref = \case
  Object schema -> do
    case KeyMap.lookup "type" schema of
      Just (String "object") -> Right ()
      _ -> invalid "root type must be object"
    properties <- case KeyMap.lookup "properties" schema of
      Nothing -> Right KeyMap.empty
      Just (Object p) -> Right p
      Just _ -> invalid "properties must be an object"
    required <- case KeyMap.lookup "required" schema of
      Nothing -> Right []
      Just (Array xs) -> traverse requiredName (toList xs)
      Just _ -> invalid "required must be an array of strings"
    traverse_ (validatePropertySchema ref) (KeyMap.toList properties)
    case find (not . (`KeyMap.member` properties) . Key.fromText) required of
      Nothing -> Right ()
      Just name -> invalid ("required property has no schema: " <> name)
  _ -> invalid "schema must be a JSON object"
  where
    invalid :: Text -> Either ToolCatalogError a
    invalid = Left . InvalidToolSchema ref
    requiredName (String name) = Right name
    requiredName _ = invalid "required must contain only strings"

validatePropertySchema :: ToolRef -> (Key.Key, Value) -> Either ToolCatalogError ()
validatePropertySchema ref (name, Object propertySchema) =
  case KeyMap.lookup "type" propertySchema of
    Nothing -> Right ()
    Just (String kind)
      | kind `elem` ["string", "integer", "number", "boolean", "object", "array"] -> Right ()
      | otherwise -> invalid ("unsupported type for " <> key <> ": " <> kind)
    Just _ -> invalid ("type for " <> key <> " must be a string")
  where
    key = Key.toText name
    invalid = Left . InvalidToolSchema ref
validatePropertySchema ref (name, _) =
  Left (InvalidToolSchema ref ("property schema must be an object: " <> Key.toText name))

validateArguments :: CatalogTool -> Value -> Either ToolFault ()
validateArguments view = \case
  Object args -> do
    let schema = case view.ctSchema of
          Object o -> o
          _ -> KeyMap.empty -- impossible after catalog validation
        properties = case KeyMap.lookup "properties" schema of
          Just (Object p) -> p
          _ -> KeyMap.empty
        required = case KeyMap.lookup "required" schema of
          Just (Array xs) -> [name | String name <- toList xs]
          _ -> []
    case find (not . (`KeyMap.member` args) . Key.fromText) required of
      Just name -> Left (rejectedFault view ("missing required property: " <> name))
      Nothing -> traverse_ (validatePresent args view) (KeyMap.toList properties)
  _ -> Left (rejectedFault view "arguments must be a JSON object")

validatePresent :: Object -> CatalogTool -> (Key.Key, Value) -> Either ToolFault ()
validatePresent args view (name, Object propertySchema) = case KeyMap.lookup name args of
  Nothing -> Right ()
  Just value -> do
    case KeyMap.lookup "type" propertySchema of
      Nothing -> Right ()
      Just (String kind)
        | valueHasType kind value -> Right ()
        | otherwise -> Left (rejectedFault view (Key.toText name <> " must be " <> kind))
      _ -> Right ()
    validateEnum value
    validateBounds value
  where
    validateEnum value = case KeyMap.lookup "enum" propertySchema of
      Just (Array allowed)
        | value `notElem` allowed ->
            Left (rejectedFault view (Key.toText name <> " is not an allowed value"))
      _ -> Right ()

    validateBounds (Number n) = do
      case KeyMap.lookup "minimum" propertySchema of
        Just (Number minimumValue)
          | n < minimumValue -> Left (rejectedFault view (Key.toText name <> " is below minimum"))
        _ -> Right ()
      case KeyMap.lookup "maximum" propertySchema of
        Just (Number maximumValue)
          | n > maximumValue -> Left (rejectedFault view (Key.toText name <> " is above maximum"))
        _ -> Right ()
    validateBounds _ = Right ()
validatePresent _ view (name, _) =
  Left (rejectedFault view ("invalid registered schema for " <> Key.toText name))

valueHasType :: Text -> Value -> Bool
valueHasType "string" String {} = True
valueHasType "integer" (Number n) = case floatingOrInteger @Double @Integer n of
  Right _ -> True
  Left _ -> False
valueHasType "number" Number {} = True
valueHasType "boolean" Bool {} = True
valueHasType "object" Object {} = True
valueHasType "array" Array {} = True
valueHasType _ _ = False

rejectedFault :: CatalogTool -> Text -> ToolFault
rejectedFault view message =
  ToolFault
    { tfCode = "invalid_arguments",
      tfMessage = message,
      tfRetryClass = view.ctDefinition.tdRetryClass
    }
