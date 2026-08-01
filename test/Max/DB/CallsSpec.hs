module Max.DB.CallsSpec (spec) where

import Data.Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.Text (Text)
import Max.DB.Calls (redactDataUrls)
import Test.Hspec

spec :: Spec
spec =
  describe "redactDataUrls" $ do
    it "redacts OpenAI data URLs" $
      redactDataUrls (String "data:image/png;base64,AAAA")
        `shouldBe` String "data:image/png;base64,…(4 chars)"

    it "redacts Anthropic base64 source objects" $ do
      let redacted =
            redactDataUrls $
              object
                [ "type" .= ("base64" :: Text),
                  "media_type" .= ("image/jpeg" :: Text),
                  "data" .= ("QUJDRA==" :: Text)
                ]
      case redacted of
        Object o -> KM.lookup "data" o `shouldBe` Just (String "…(8 chars)")
        _ -> expectationFailure "expected object"

    it "does not rewrite unrelated base64-shaped objects" $
      let value =
            object
              [ "type" .= ("base64" :: Text),
                "media_type" .= ("application/octet-stream" :: Text),
                "data" .= ("keep-me" :: Text)
              ]
       in redactDataUrls value `shouldBe` value
