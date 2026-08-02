module Max.ModelCatalogSpec (spec) where

import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Max.ModelCatalog
import Test.Hspec

spec :: Spec
spec = describe "ModelCatalog" $ do
  it "keeps a valid default and lists profile names deterministically" $ do
    defaultModelName validCatalog `shouldBe` "vision"
    modelProfileNames validCatalog `shouldBe` ["text", "vision"]

  it "rejects a default that is absent from the single source of truth" $
    case mkModelCatalog "missing" capabilities of
      Left err -> err `shouldBe` DefaultModelMissing "missing"
      Right _ -> expectationFailure "accepted an absent default model"

  it "exposes prompt capabilities through the safe public API" $ do
    lookupModelCapabilities "vision" validCatalog
      `shouldBe` Just (ModelCapabilities True True (Just "high") limits)

  it "distinguishes an unknown profile explicitly" $ do
    lookupModelCapabilities "missing" validCatalog `shouldBe` Nothing

  it "resolves an attachment-aware input budget without spending output reserve twice" $ do
    contextInputBudget limits False `shouldBe` 28672
    contextInputBudget limits True `shouldBe` 24576

validCatalog :: ModelCatalog
validCatalog = case mkModelCatalog "vision" capabilities of
  Left err -> error (show err)
  Right catalog -> catalog

capabilities :: Map.Map Text ModelCapabilities
capabilities =
  Map.fromList
    [ ("text", ModelCapabilities False False Nothing limits),
      ("vision", ModelCapabilities True True (Just "high") limits)
    ]

limits :: ContextLimits
limits = ContextLimits 32768 4096 4096 4096
