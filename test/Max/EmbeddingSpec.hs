module Max.EmbeddingSpec (spec) where

import Data.Aeson (Value, decode, object, (.=))
import Max.Embedding (EmbeddingConfig (..), embeddingRequest)
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
  where
    config =
      EmbeddingConfig
        { ecBaseUrl = "https://embedding.example/v1/",
          ecApiKey = Just "test-key",
          ecModel = "test-model",
          ecTimeoutSeconds = 30
        }
