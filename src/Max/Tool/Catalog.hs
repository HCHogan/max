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
import Data.Aeson (Value (..), encode)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Lazy qualified as LBS
import Data.Foldable (foldlM, traverse_)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Max.Schema
  ( SchemaDialect (ToolSchema),
    parseSchema,
    schemaValue,
    validateSchemaValue,
  )
import Max.Tool.Types

newtype ToolCatalog = ToolCatalog (Map ToolRef CatalogTool)
  deriving stock (Show, Eq)

catalogTools :: ToolCatalog -> [CatalogTool]
catalogTools (ToolCatalog tools) = Map.elems tools

catalogSpecs :: ToolCatalog -> [ToolSpec]
catalogSpecs = map (\view -> ToolSpec view.ctDefinition.tdRef.unToolRef view.ctDescription (schemaValue view.ctSchema)) . catalogTools

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
          case spec.specSchema of
            Object fields | KeyMap.lookup "type" fields == Just (String "object") -> pure ()
            _ -> Left (InvalidToolSchema ref "root type must be object")
          schema <- either (Left . InvalidToolSchema ref) Right (parseSchema ToolSchema spec.specSchema)
          pure (CatalogTool definition spec.specDescription schema (schemaHash spec.specSchema))
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
  | definition.tdRef `elem` map ToolRef ["run_code", "run_code_resume", "run_code_cancel", "execution_wait"] = bad "run_code is reserved for the orchestration adapter; it cannot own the leaf scheduling gate"
  | definition.tdSchemaVersion.unSchemaVersion <= 0 = bad "schema version must be positive"
  | definition.tdDeadline.toolDeadlineSeconds <= 0 = bad "start-to-close deadline must be positive"
  | definition.tdCallMode /= WorkCall && definition.tdParallelism /= SequentialOnly =
      bad "execution checkpoint and finish calls must be sequential"
  | definition.tdParallelism == ParallelSafe && any isMutating definition.tdEffects =
      bad "mutating, sending, LLM, or reflective tools cannot declare ParallelSafe"
  | definition.tdParallelism == ParallelIndependent && any isControlEffect definition.tdEffects =
      bad "sending, LLM, or reflective tools cannot declare ParallelIndependent"
  | definition.tdRetryClass == RetrySafe && any isMutating definition.tdEffects =
      bad "mutating, sending, LLM, or reflective tools cannot declare RetrySafe"
  | otherwise = Right ()
  where
    bad = Left . InvalidToolMetadata definition.tdRef

isControlEffect :: ToolEffect -> Bool
isControlEffect EffectRead {} = False
isControlEffect EffectWrite {} = False
isControlEffect _ = True

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

validateArguments :: CatalogTool -> Value -> Either ToolFault ()
validateArguments view = either (Left . rejectedFault view) Right . validateSchemaValue view.ctSchema

rejectedFault :: CatalogTool -> Text -> ToolFault
rejectedFault view message =
  ToolFault
    { tfCode = "invalid_arguments",
      tfMessage = message,
      tfRetryClass = view.ctDefinition.tdRetryClass
    }
