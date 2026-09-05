module Max.RuntimeConfigSpec (spec) where

import Control.Concurrent.STM (atomically)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Time (minutesToTimeZone)
import Effectful.Log (LogLevel (LogInfo))
import Max.Intent.Types (IntentConfig (..))
import Max.MaxOps.Types (defaultMaxOpsConfig)
import Max.ModelCatalog
import Max.RuntimeConfig
import Test.Hspec

spec :: Spec
spec = describe "runtime configuration generations" $ do
  it "publishes all values/resources as one monotonically increasing snapshot" $ do
    store <- newRuntimeConfigStore (values "old") emptyResources
    (old, new) <- atomically (publishRuntimeConfigSTM store (values "new") emptyResources)
    old.rsGeneration `shouldBe` ConfigGeneration 1
    new.rsGeneration `shouldBe` ConfigGeneration 2
    new.rsValues.rvPersona `shouldBe` "new"
    current <- currentRuntimeSnapshot store
    current.rsGeneration `shouldBe` ConfigGeneration 2
    current.rsValues.rvDefaultModel `shouldBe` "new"

  it "retains a leased old generation until its dispatch finalizer releases it" $ do
    store <- newRuntimeConfigStore (values "old") emptyResources
    lease <- atomically (acquireRuntimeConfigSTM store)
    _ <- atomically (publishRuntimeConfigSTM store (values "new") emptyResources)
    lookupRuntimeSnapshot store (ConfigGeneration 1) >>= \case
      Just snapshot -> do
        snapshot.rsValues.rvPersona `shouldBe` "old"
        snapshot.rsValues.rvDefaultModel `shouldBe` "old"
        snapshot.rsValues.rvBrowserProxy `shouldBe` Just "old"
        snapshot.rsValues.rvMemoryExtract `shouldBe` Just "old"
        snapshot.rsValues.rvIntent `shouldBe` Just (intent "old")
      Nothing -> expectationFailure "leased generation was collected"
    current <- currentRuntimeSnapshot store
    current.rsValues.rvPersona `shouldBe` "new"
    current.rsValues.rvDefaultModel `shouldBe` "new"
    current.rsValues.rvBrowserProxy `shouldBe` Just "new"
    current.rsValues.rvMemoryExtract `shouldBe` Just "new"
    current.rsValues.rvIntent `shouldBe` Just (intent "new")
    retainedRuntimeGenerations store `shouldReturn` [ConfigGeneration 1, ConfigGeneration 2]
    atomically (releaseRuntimeConfigSTM lease)
    lookupRuntimeSnapshot store (ConfigGeneration 1) >>= \case
      Nothing -> pure ()
      Just _ -> expectationFailure "released generation was retained"
    retainedRuntimeGenerations store `shouldReturn` [ConfigGeneration 2]

  it "drops an unleased superseded generation at publication" $ do
    store <- newRuntimeConfigStore (values "old") emptyResources
    _ <- atomically (publishRuntimeConfigSTM store (values "new") emptyResources)
    retainedRuntimeGenerations store `shouldReturn` [ConfigGeneration 2]

emptyResources :: RuntimeResources
emptyResources = RuntimeResources Nothing [] []

values :: Text -> RuntimeValues
values name =
  RuntimeValues
    { rvPersona = name,
      rvForceRawContext = False,
      rvDebugDefault = False,
      rvStickerDefault = True,
      rvDefaultModel = name,
      rvTimeZone = minutesToTimeZone 480,
      rvTurnSilenceSeconds = 600,
      rvOwners = [],
      rvSearch = Nothing,
      rvMaxOps = defaultMaxOpsConfig,
      rvCliProxy = Nothing,
      rvBrowserProxy = Just name,
      rvMemoryExtract = Just name,
      rvIntent = Just (intent name),
      rvEmbeddingEnabled = False,
      rvModelCatalog = catalog name,
      rvLogLevel = LogInfo
    }

catalog :: Text -> ModelCatalog
catalog name = case mkModelCatalog name (Map.singleton name capabilities) of
  Left err -> error (show err)
  Right result -> result
  where
    capabilities = ModelCapabilities False False Nothing defaultContextLimits

intent :: Text -> IntentConfig
intent profile = IntentConfig profile 60 10 20
