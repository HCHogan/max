module Max.Effects.ToolsSpec (spec) where

import Data.Aeson (Value, object, (.=))
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Set qualified as Set
import Effectful (liftIO, runEff)
import Max.Effects.LLM (ToolSpec (..))
import Max.Effects.Tools
import Test.Hspec

schema :: Value
schema =
  object
    [ "type" .= ("object" :: String),
      "properties"
        .= object
          [ "value" .= object ["type" .= ("integer" :: String), "minimum" .= (1 :: Int)]
          ],
      "required" .= (["value"] :: [String])
    ]

definition :: ToolRef -> Set.Set ToolEffect -> ToolParallelism -> ToolRetryClass -> ToolDefinition
definition ref effects parallelism retry =
  ToolDefinition
    { tdRef = ref,
      tdSchemaVersion = SchemaVersion 1,
      tdEffects = effects,
      tdParallelism = parallelism,
      tdRetryClass = retry,
      tdAuthorities = Set.singleton CurrentConversation
    }

readDefinition :: ToolDefinition
readDefinition =
  definition (ToolRef "read") (Set.singleton (EffectRead "test.db")) ParallelSafe RetrySafe

readTool :: Tool es
readTool =
  Tool
    { toolName = "read",
      toolDescription = "read a value",
      toolSchema = schema,
      toolRun = pure . Right
    }

spec :: Spec
spec = describe "validated tool kernel" $ do
  it "rejects duplicate definitions and runners" $ do
    buildToolCatalog [readDefinition, readDefinition] [readTool]
      `shouldSatisfy` isDuplicateDefinition
    buildToolCatalog [readDefinition] [readTool, readTool]
      `shouldSatisfy` isDuplicateRunner

  it "requires definitions and runners to describe the exact same catalog" $ do
    buildToolCatalog [] [readTool]
      `shouldSatisfy` isMissingDefinition
    buildToolCatalog [readDefinition] []
      `shouldSatisfy` isMissingRunner

  it "rejects malformed schemas and unsafe metadata" $ do
    let badSchema = readTool {toolSchema = object ["type" .= ("array" :: String)]}
        unsafe = readDefinition {tdEffects = Set.singleton (EffectWrite "test.db")}
    buildToolCatalog [readDefinition] [badSchema]
      `shouldSatisfy` isInvalidSchema
    buildToolCatalog [unsafe] [readTool]
      `shouldSatisfy` isInvalidMetadata

  it "validates arguments before acquiring the runner" $ do
    called <- newIORef False
    let runner = readTool {toolRun = \_ -> liftIO (writeIORef called True) >> pure (Right (object []))}
    catalog <- expectCatalog (buildToolCatalog [readDefinition] [runner])
    outcome <- runEff . runTools catalog $ invokeTool "read" (object ["value" .= (0 :: Int)])
    outcome `shouldSatisfy` isRejected
    readIORef called `shouldReturn` False

  it "classifies read failures before effect and writes conservatively as outcome unknown" $ do
    let failing name =
          Tool
            { toolName = name,
              toolDescription = "fails",
              toolSchema = schema,
              toolRun = \_ -> pure (Left "boom")
            }
        writeDefinition =
          definition
            (ToolRef "write")
            (Set.singleton (EffectWrite "test.db"))
            SequentialOnly
            RetryUnsafe
    catalog <- expectCatalog (buildToolCatalog [readDefinition, writeDefinition] [failing "read", failing "write"])
    readOutcome <- runEff . runTools catalog $ invokeTool "read" (object ["value" .= (1 :: Int)])
    writeOutcome <- runEff . runTools catalog $ invokeTool "write" (object ["value" .= (1 :: Int)])
    readOutcome `shouldSatisfy` isFailedBeforeEffect
    writeOutcome `shouldSatisfy` isOutcomeUnknown
    outcomeResult writeOutcome `shouldBe` Left "boom (outcome unknown; not retried)"

  it "publishes the same validated catalog to model specs and inspection" $ do
    catalog <- expectCatalog (buildToolCatalog [readDefinition] [readTool])
    (specs, views) <- runEff . runTools catalog $ (,) <$> listToolSpecs <*> listCatalogTools
    map (.specName) specs `shouldBe` ["read"]
    map (.ctDefinition.tdRef) views `shouldBe` [ToolRef "read"]
    map (.ctSchemaHash) views `shouldSatisfy` notElem (SchemaHash "")
  where
    isDuplicateDefinition (Left DuplicateToolDefinition {}) = True
    isDuplicateDefinition _ = False
    isDuplicateRunner (Left DuplicateToolRunner {}) = True
    isDuplicateRunner _ = False
    isMissingDefinition (Left (MissingToolDefinition (ToolRef "read"))) = True
    isMissingDefinition _ = False
    isMissingRunner (Left (MissingToolRunner (ToolRef "read"))) = True
    isMissingRunner _ = False
    isInvalidSchema (Left InvalidToolSchema {}) = True
    isInvalidSchema _ = False
    isInvalidMetadata (Left InvalidToolMetadata {}) = True
    isInvalidMetadata _ = False
    isRejected ToolRejected {} = True
    isRejected _ = False
    isFailedBeforeEffect ToolFailedBeforeEffect {} = True
    isFailedBeforeEffect _ = False
    isOutcomeUnknown ToolOutcomeUnknown {} = True
    isOutcomeUnknown _ = False

expectCatalog :: Either ToolCatalogError a -> IO a
expectCatalog = \case
  Left err -> expectationFailure ("catalog construction failed: " <> show err) >> fail "unreachable"
  Right catalog -> pure catalog
