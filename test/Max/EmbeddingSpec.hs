module Max.EmbeddingSpec (spec) where

import Data.Aeson (Value, decode, object, (.=))
import Max.Embedding
  ( EmbeddingConfig (..),
    EmbeddingRecord (..),
    embeddingRequest,
    makeEmbeddingRecord,
    newEmbedClient,
  )
import Max.HttpRuntime (newHttpRuntime)
import Network.HTTP.Client (Request (..), RequestBody (..))
import Test.Hspec

spec :: Spec
spec = describe "embeddingRequest" $ do
  it "builds a POST to the OpenAI-compatible embeddings endpoint" $ do
    result <- embeddingRequest config ["first", "second"]
    case result of
      Left failure -> expectationFailure ("request failed: " <> show failure)
      Right request -> do
        request.method `shouldBe` "POST"
        request.path `shouldBe` "/v1/embeddings"
        lookup "Authorization" request.requestHeaders `shouldBe` Just "Bearer test-key"
        case request.requestBody of
          RequestBodyLBS body ->
            decode body
              `shouldBe` Just
                ( object
                    [ "model" .= ("test-model" :: String),
                      "input" .= (["first", "second"] :: [String])
                    ] ::
                    Value
                )
          _ -> expectationFailure "embedding body was not buffered JSON"

  it "binds a validated vector to model, dimensions, and source hash" $ do
    runtime <- newHttpRuntime
    let client = newEmbedClient runtime config
    makeEmbeddingRecord client "hello" [0.25, -0.5, 1]
      `shouldBe` Right
        EmbeddingRecord
          { erModelId = "test-model",
            erDimensions = 3,
            erContentHash = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
            erVector = "[0.25,-0.5,1.0]"
          }

  it "rejects unusable provider vectors" $ do
    runtime <- newHttpRuntime
    let client = newEmbedClient runtime config
    makeEmbeddingRecord client "hello" [] `shouldBe` Left "embedding vector is empty"
    makeEmbeddingRecord client "hello" [0 / 0]
      `shouldBe` Left "embedding vector contains a non-finite value"
  where
    config =
      EmbeddingConfig
        { ecBaseUrl = "https://embedding.example/v1/",
          ecApiKey = Just "test-key",
          ecModel = "test-model",
          ecTimeoutSeconds = 30
        }
