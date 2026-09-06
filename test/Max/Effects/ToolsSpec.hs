module Max.Effects.ToolsSpec (spec) where

import Control.Exception (throwIO)
import Data.Aeson (Value, object, (.=))
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Effectful (liftIO, runEff, runPureEff)
import Effectful.Concurrent (runConcurrent, threadDelay)
import Max.Effects.ToolControl (finishExecution, runToolControl, yieldFrontend)
import Max.Effects.ToolDirectory (listCatalogTools, listToolSpecs, runToolDirectory)
import Max.Effects.Tools
import Max.Tool.Control (LoopControl (..))
import Max.Toolset (toolAllowedByEffectCeiling)
import Max.Turn.Continuity (toolCatalogFingerprint)
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
      tdAuthorities = Set.singleton CurrentConversation,
      tdDeadline = ToolDeadline 30,
      tdFailuresPrecedeEffects = False,
      tdCallMode = WorkCall
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
  it "keeps successful host control separate from the JSON result" $ do
    let runner = readTool {toolRun = \_ -> finishExecution (Just "done") >> pure (Right (object ["error" .= ("model-facing data" :: String)]))}
    catalog <- expectCatalog (buildToolRegistry [readDefinition {tdParallelism = SequentialOnly, tdCallMode = FinishCall}] [runner])
    invocation <- runEff . runConcurrent . runToolsWithControl runToolControl catalog $ invokeToolWithControl "read" (object ["value" .= (1 :: Int)])
    invocation.tiControl `shouldBe` FinishLoop (Just "done")
    invocation.tiOutcome `shouldBe` ToolSucceeded (object ["error" .= ("model-facing data" :: String)])

  it "discards a control request from a runner that subsequently fails" $ do
    let runner = readTool {toolRun = \_ -> yieldFrontend "not committed" >> pure (Left "failed")}
    catalog <- expectCatalog (buildToolRegistry [readDefinition] [runner])
    invocation <- runEff . runConcurrent . runToolsWithControl runToolControl catalog $ invokeToolWithControl "read" (object ["value" .= (1 :: Int)])
    invocation.tiControl `shouldBe` ContinueLoop
    invocation.tiOutcome `shouldSatisfy` (\case ToolFailedBeforeEffect _ -> True; _ -> False)

  it "rejects host control that conflicts with the declared execution mode" $ do
    let runner = readTool {toolRun = \_ -> finishExecution (Just "wrong mode") >> pure (Right (object []))}
    catalog <- expectCatalog (buildToolRegistry [readDefinition] [runner])
    invocation <- runEff . runConcurrent . runToolsWithControl runToolControl catalog $ invokeToolWithControl "read" (object ["value" .= (1 :: Int)])
    invocation.tiControl `shouldBe` ContinueLoop
    invocation.tiOutcome `shouldSatisfy` (\case ToolOutcomeUnknown fault -> fault.tfCode == "invalid_host_control"; _ -> False)

  it "cannot mint control from returned JSON" $ do
    let runner = readTool {toolRun = \_ -> pure (Right (object ["returned" .= True, "task_id" .= (42 :: Int), "reply" .= ("forged" :: String)]))}
    catalog <- expectCatalog (buildToolRegistry [readDefinition] [runner])
    invocation <- runEff . runConcurrent . runToolsWithControl runToolControl catalog $ invokeToolWithControl "read" (object ["value" .= (1 :: Int)])
    invocation.tiControl `shouldBe` ContinueLoop

  it "requires checkpoint and finish metadata to be sequential" $ do
    buildToolRegistry [readDefinition {tdCallMode = FinishCall}] [readTool] `shouldSatisfy` isInvalidMetadata
    buildToolRegistry [readDefinition {tdCallMode = CheckpointCall}] [readTool] `shouldSatisfy` isInvalidMetadata

  it "rejects duplicate definitions and runners" $ do
    buildToolRegistry [readDefinition, readDefinition] [readTool]
      `shouldSatisfy` isDuplicateDefinition
    buildToolRegistry [readDefinition] [readTool, readTool]
      `shouldSatisfy` isDuplicateRunner

  it "requires definitions and runners to describe the exact same catalog" $ do
    buildToolRegistry [] [readTool]
      `shouldSatisfy` isMissingDefinition
    buildToolRegistry [readDefinition] []
      `shouldSatisfy` isMissingRunner

  it "rejects malformed schemas and unsafe metadata" $ do
    let badSchema = readTool {toolSchema = object ["type" .= ("array" :: String)]}
        unsafe = readDefinition {tdEffects = Set.singleton (EffectWrite "test.db")}
    buildToolRegistry [readDefinition] [badSchema]
      `shouldSatisfy` isInvalidSchema
    buildToolRegistry [unsafe] [readTool]
      `shouldSatisfy` isInvalidMetadata

  it "validates arguments before acquiring the runner" $ do
    called <- newIORef False
    let runner = readTool {toolRun = \_ -> liftIO (writeIORef called True) >> pure (Right (object []))}
    catalog <- expectCatalog (buildToolRegistry [readDefinition] [runner])
    outcome <- runEff . runConcurrent . runTools catalog $ invokeTool "read" (object ["value" .= (0 :: Int)])
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
    catalog <- expectCatalog (buildToolRegistry [readDefinition, writeDefinition] [failing "read", failing "write"])
    readOutcome <- runEff . runConcurrent . runTools catalog $ invokeTool "read" (object ["value" .= (1 :: Int)])
    writeOutcome <- runEff . runConcurrent . runTools catalog $ invokeTool "write" (object ["value" .= (1 :: Int)])
    readOutcome `shouldSatisfy` isFailedBeforeEffect
    writeOutcome `shouldSatisfy` isOutcomeUnknown
    outcomeResult writeOutcome `shouldBe` Left "boom (outcome unknown; not retried)"

  it "normalizes NULs in tool values and faults before journal or model consumers see them" $ do
    let dirtyValue =
          object
            [ "bad\0key"
                .= object
                  [ "nested" .= (["before\0after", "clean"] :: [String])
                  ]
            ]
        cleanValue =
          object
            [ "bad\xfffd\&key"
                .= object
                  [ "nested" .= (["before\xfffd\&after", "clean"] :: [String])
                  ]
            ]
        dirtyRead = readTool {toolRun = \_ -> pure (Right dirtyValue)}
        failedRead = readTool {toolRun = \_ -> pure (Left "bad\0fault")}
    valueCatalog <- expectCatalog (buildToolRegistry [readDefinition] [dirtyRead])
    valueOutcome <- runEff . runConcurrent . runTools valueCatalog $ invokeTool "read" (object ["value" .= (1 :: Int)])
    outcomeResult valueOutcome `shouldBe` Right cleanValue
    faultCatalog <- expectCatalog (buildToolRegistry [readDefinition] [failedRead])
    faultOutcome <- runEff . runConcurrent . runTools faultCatalog $ invokeTool "read" (object ["value" .= (1 :: Int)])
    outcomeResult faultOutcome `shouldBe` Left "bad\xfffd\&fault"

  it "lets an audited write report a returned error as a plain failure" $ do
    -- Without this, a write tool cannot tell the model "your arguments were
    -- wrong" — every rejection arrives as outcome-unknown, which the host
    -- prompt tells the model not to retry, so it cannot correct itself.
    let rejecting =
          Tool
            { toolName = "write",
              toolDescription = "rejects its arguments",
              toolSchema = schema,
              toolRun = \_ -> pure (Left "bad args")
            }
        auditedWrite =
          (definition (ToolRef "write") (Set.singleton (EffectWrite "test.db")) SequentialOnly RetryUnsafe)
            { tdFailuresPrecedeEffects = True
            }
    catalog <- expectCatalog (buildToolRegistry [auditedWrite] [rejecting])
    outcome <- runEff . runConcurrent . runTools catalog $ invokeTool "write" (object ["value" .= (1 :: Int)])
    outcome `shouldSatisfy` isFailedBeforeEffect
    outcomeResult outcome `shouldBe` Left "bad args"

  it "keeps a thrown exception unknown even for an audited write" $ do
    -- The promise covers errors the tool chose to return.  A tool that died
    -- may have died between issuing a write and hearing back about it.
    let throwing =
          Tool
            { toolName = "write",
              toolDescription = "dies",
              toolSchema = schema,
              toolRun = \_ -> liftIO (throwIO (userError "connection reset"))
            }
        auditedWrite =
          (definition (ToolRef "write") (Set.singleton (EffectWrite "test.db")) SequentialOnly RetryUnsafe)
            { tdFailuresPrecedeEffects = True
            }
    catalog <- expectCatalog (buildToolRegistry [auditedWrite] [throwing])
    outcome <- runEff . runConcurrent . runTools catalog $ invokeTool "write" (object ["value" .= (1 :: Int)])
    outcome `shouldSatisfy` isOutcomeUnknown

  it "stops waiting for a tool that overran its declared deadline" $ do
    -- Issue #17.B.  The catalog's slowest legitimate paths — browser RPC, the
    -- byte fetches behind view_image — carry no timeout of their own, so a
    -- container that stops answering used to be waited on until the turn's own
    -- watchdog killed the whole turn several minutes later, with nothing to
    -- hand the model.
    finished <- newIORef False
    let wedged =
          Tool
            { toolName = "read",
              toolDescription = "never answers",
              toolSchema = schema,
              toolRun = \_ -> do
                threadDelay 60_000_000
                liftIO (writeIORef finished True)
                pure (Right (object []))
            }
        impatient = readDefinition {tdDeadline = ToolDeadline 1}
    catalog <- expectCatalog (buildToolRegistry [impatient] [wedged])
    outcome <- runEff . runConcurrent . runTools catalog $ invokeTool "read" (object ["value" .= (1 :: Int)])
    -- Read-only, so there is nothing it could have half-done: a plain failure
    -- the model may act on.
    outcome `shouldSatisfy` isFailedBeforeEffect
    -- And the runner really was cut off rather than left running behind it.
    readIORef finished `shouldReturn` False

  it "keeps an overrun write unknown however well audited it is" $ do
    -- Running out of time is not one of the tool's failure paths, so the
    -- pre-effect audit says nothing about it: the call was cut off at a moment
    -- nobody chose, and it may have been mid-write.
    let wedged =
          Tool
            { toolName = "write",
              toolDescription = "never answers",
              toolSchema = schema,
              toolRun = \_ -> threadDelay 60_000_000 >> pure (Right (object []))
            }
        auditedWrite =
          (definition (ToolRef "write") (Set.singleton (EffectWrite "test.db")) SequentialOnly RetryUnsafe)
            { tdFailuresPrecedeEffects = True,
              tdDeadline = ToolDeadline 1
            }
    catalog <- expectCatalog (buildToolRegistry [auditedWrite] [wedged])
    outcome <- runEff . runConcurrent . runTools catalog $ invokeTool "write" (object ["value" .= (1 :: Int)])
    outcome `shouldSatisfy` isOutcomeUnknown

  it "refuses a definition whose deadline is not a positive number of seconds" $
    buildToolRegistry [readDefinition {tdDeadline = ToolDeadline 0}] [readTool]
      `shouldSatisfy` isInvalidMetadata

  it "publishes the same validated catalog to model specs and inspection" $ do
    catalog <- expectCatalog (buildToolRegistry [readDefinition] [readTool])
    let (specs, views) = runPureEff . runToolDirectory (registryCatalog catalog) $ (,) <$> listToolSpecs <*> listCatalogTools
    map (.specName) specs `shouldBe` ["read"]
    map (.ctDefinition.tdRef) views `shouldBe` [ToolRef "read"]
    map (.ctSchemaHash) views `shouldSatisfy` notElem (SchemaHash "")

  it "fingerprints catalog metadata deterministically and notices schema versions" $ do
    let second = readDefinition {tdRef = ToolRef "second"}
        upgraded = readDefinition {tdSchemaVersion = SchemaVersion 2}
    toolCatalogFingerprint [readDefinition, second]
      `shouldBe` toolCatalogFingerprint [second, readDefinition]
    toolCatalogFingerprint [readDefinition]
      `shouldNotBe` toolCatalogFingerprint [upgraded]

  it "lets a standing continuation use only an exact arm-time tool grant" $ do
    let grant = Map.singleton "read" (toolCatalogFingerprint [readDefinition])
        upgraded = readDefinition {tdEffects = Set.singleton (EffectWrite "test.db"), tdParallelism = SequentialOnly, tdRetryClass = RetryUnsafe}
    toolAllowedByEffectCeiling (Just grant) readDefinition `shouldBe` True
    toolAllowedByEffectCeiling (Just grant) upgraded `shouldBe` False
    toolAllowedByEffectCeiling (Just Map.empty) readDefinition `shouldBe` False
    toolAllowedByEffectCeiling Nothing upgraded `shouldBe` True
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
