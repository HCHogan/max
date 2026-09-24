module Max.ModelCatalogSpec (spec) where

import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Max.ModelCatalog
import Test.Hspec
import Test.QuickCheck (chooseInt, forAll, property)

spec :: Spec
spec = describe "ModelCatalog" $ do
  it "ships roomy long-lived group-chat defaults" $
    defaultContextLimits
      `shouldBe` ContextLimits
        { maxInputTokens = 114688,
          reservedOutputTokens = 16384,
          attachmentReserve = 16384,
          toolRoundReserve = 16384,
          workingBudget = Nothing
        }

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

  it "derives the 262K combined window instead of granting 262K input" $ do
    contextLimitsForWindow 262144 Nothing True
      `shouldBe` Right (ContextLimits 229376 32768 32768 32768 Nothing)
    fmap (`contextInputBudget` False) (contextLimitsForWindow 262144 Nothing True) `shouldBe` Right 196608
    fmap (`contextInputBudget` True) (contextLimitsForWindow 262144 Nothing True) `shouldBe` Right 163840

  it "preserves the 128K defaults and reallocates an explicit output cap" $ do
    contextLimitsForWindow 131072 Nothing True `shouldBe` Right defaultContextLimits
    contextLimitsForWindow 262144 (Just 16384) False
      `shouldBe` Right (ContextLimits 245760 16384 0 32768 Nothing)

  it "rejects impossible combined windows and output caps" $ do
    contextLimitsForWindow 0 Nothing False `shouldSatisfy` either (const True) (const False)
    contextLimitsForWindow 1 Nothing False `shouldSatisfy` either (const True) (const False)
    contextLimitsForWindow 1024 (Just 0) False `shouldSatisfy` either (const True) (const False)
    contextLimitsForWindow 1024 (Just 1024) False `shouldSatisfy` either (const True) (const False)

  it "never allocates output or reserves outside the total window" $
    property $ forAll (chooseInt (2, 1048576)) $ \window ->
      case contextLimitsForWindow window Nothing True of
        Left _ -> False
        Right resolved ->
          resolved.maxInputTokens + resolved.reservedOutputTokens == window
            && contextInputBudget resolved True + resolved.attachmentReserve + resolved.toolRoundReserve + resolved.reservedOutputTokens == window
            && contextInputBudget resolved False + resolved.toolRoundReserve + resolved.reservedOutputTokens == window

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
limits = ContextLimits 32768 4096 4096 4096 Nothing
