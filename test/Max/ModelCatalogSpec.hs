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
    mkModelCatalog "missing" profiles
      `shouldBe` Left (DefaultModelMissing "missing")

  it "projects prompt capabilities without endpoint credentials" $ do
    lookupModelCapabilities "vision" validCatalog
      `shouldBe` Just (ModelCapabilities True True (Just "high"))

  it "distinguishes an unknown profile explicitly" $ do
    lookupModelCapabilities "missing" validCatalog `shouldBe` Nothing
    lookupCompletionProfile "missing" validCatalog `shouldBe` Nothing

validCatalog :: ModelCatalog
validCatalog = case mkModelCatalog "vision" profiles of
  Left err -> error (show err)
  Right catalog -> catalog

profiles :: Map.Map Text LLMProfile
profiles =
  Map.fromList
    [ ("text", profile False False Nothing),
      ("vision", profile True True (Just "high"))
    ]

profile :: Bool -> Bool -> Maybe Text -> LLMProfile
profile multimodal historyAsTurns effort =
  LLMProfile
    { baseUrl = "https://llm.invalid/v1",
      apiKey = "secret-that-must-not-enter-capabilities",
      model = "fixture",
      maxTokens = 1024,
      temperature = Nothing,
      effort,
      timeoutSeconds = 30,
      protocol = ProtocolOpenAI,
      multimodal,
      historyAsTurns,
      stream = True
    }
