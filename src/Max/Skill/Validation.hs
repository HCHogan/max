-- | Fixture-only guest execution. This function accepts metadata and data, never
-- application tool closures, a production session, a database or an IO callback.
module Max.Skill.Validation (validateFixtures) where

import Control.Concurrent.STM
import Control.Monad (forM)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Effectful
import Effectful.Concurrent (runConcurrent)
import Max.CodeMode.Execution
import Max.CodeMode.JavaScript
import Max.CodeMode.Wasm
import Max.Effects.Tools
import Max.Execution.Tools
import Max.Skill.Authoring
import Max.Skill.Package
import Max.Tool.Catalog (validateArguments)

validateFixtures :: [CatalogTool] -> DraftVersion -> IO ValidationReport
validateFixtures available draft = case validateDraft draft.dvContent of
  Left err -> pure (ValidationReport [err])
  Right () -> do
    results <- forM (zip [1 :: Int ..] draft.dvContent.dcFixtures) $ \(index, fixture) -> do
      failures <- runFixture available draft fixture
      pure ["fixture " <> T.pack (show index) <> ": " <> err | err <- failures]
    pure (ValidationReport (concat results))

runFixture :: [CatalogTool] -> DraftVersion -> Fixture -> IO [Text]
runFixture available draft fixture = case Map.lookup fixture.fxEntry draft.dvContent.dcPackage.spWorkflows of
  Nothing -> pure ["workflow missing"]
  Just workflow -> do
    remaining <- newTVarIO fixture.fxCalls
    mismatches <- newTVarIO ([] :: [Text])
    -- Deterministic fixture consumption follows submitted batch order. This does
    -- not claim to test timing or concurrency of live tool implementations.
    let catalog = [t {ctDefinition = t.ctDefinition {tdParallelism = SequentialOnly}} | t <- available, t.ctDefinition.tdRef.unToolRef `elem` workflow.wfTools]
        runner entry = Tool entry.ctDefinition.tdRef.unToolRef entry.ctDescription entry.ctSchema $ \args -> liftIO . atomically $ do
          pending <- readTVar remaining
          case pending of
            call : rest | call.fcTool == entry.ctDefinition.tdRef.unToolRef && call.fcArgs == args -> writeTVar remaining rest >> pure call.fcResult
            _ -> do
              modifyTVar' mismatches ("unexpected fixture call or arguments" :)
              pure (Left "fixture call does not match")
        validCalls = sequence_ [maybe (Left (ToolFault "unavailable" "fixture tool unavailable" RetrySafe)) (\entry -> validateArguments entry c.fcArgs) (lookupTool c.fcTool catalog) | c <- fixture.fxCalls]
    case validCalls of
      Left fault -> pure [fault.tfMessage]
      Right () -> case buildToolRegistry (map (.ctDefinition) catalog) (map runner catalog) of
        Left err -> pure [T.pack (show err)]
        Right registry -> do
          result <- runEff . runConcurrent . runTools registry $ do
            session <- newExecutionSession (Just 32)
            runWasmProgram session noJournal catalog limits (workflowProgram catalog (draft.dvContent.dcName <> "/" <> fixture.fxEntry) (T.pack (show draft.dvRevision)) workflow fixture.fxArgs)
          unused <- readTVarIO remaining
          bad <- readTVarIO mismatches
          pure $ bad <> ["unused fixture calls" | not (null unused)] <> ["guest did not complete: " <> T.pack (show result.cmExit) | result.cmExit /= WasmCompleted] <> ["output differs from expected" | result.cmOutput /= Just fixture.fxExpected] <> ["rejected guest call" | any ((== "rejected") . (.ccOutcome)) result.cmCalls]
  where
    lookupTool name = foldr (\t rest -> if t.ctDefinition.tdRef.unToolRef == name then Just t else rest) Nothing
    limits = javaScriptLimits {wlFuel = 50000000, wlTimeoutMicros = 5 * 1000000, wlHostCalls = 64}
    noJournal = ExecutionHooks (pure ()) (\_ _ -> pure Nothing) (\_ _ -> pure ()) (\_ _ -> pure ())
