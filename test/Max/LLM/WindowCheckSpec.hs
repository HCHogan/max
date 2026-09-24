module Max.LLM.WindowCheckSpec (spec) where

import Data.Aeson (Value, decode)
import Data.ByteString.Lazy qualified as LBS
import Data.Maybe (fromMaybe)
import Max.LLM.WindowCheck (reportedContextWindow)
import Test.Hspec

listing :: LBS.ByteString -> Value
listing = fromMaybe (error "fixture JSON") . decode

spec :: Spec
spec = describe "server-reported context windows" $ do
  it "reads llama-swap's context_length for the configured model id" $
    reportedContextWindow "qwen3.8-27b" (listing "{\"object\":\"list\",\"data\":[{\"id\":\"qwen3.8-27b\",\"object\":\"model\",\"owned_by\":\"llamaswap\",\"context_length\":262144,\"max_context_length\":262144}]}")
      `shouldBe` Just 262144

  it "reads vLLM's max_model_len and ignores other models" $ do
    let models = listing "{\"data\":[{\"id\":\"small\",\"max_model_len\":32768},{\"id\":\"big\",\"max_model_len\":131072}]}"
    reportedContextWindow "big" models `shouldBe` Just 131072
    reportedContextWindow "missing" models `shouldBe` Nothing

  it "treats listings without a positive length as unreported" $ do
    reportedContextWindow "m" (listing "{\"data\":[{\"id\":\"m\"}]}") `shouldBe` Nothing
    reportedContextWindow "m" (listing "{\"data\":[{\"id\":\"m\",\"context_length\":0}]}") `shouldBe` Nothing
    reportedContextWindow "m" (listing "{\"object\":\"list\"}") `shouldBe` Nothing
