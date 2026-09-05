module Max.Browser.ProfileSpec (spec) where

import Data.Aeson
import Data.Either (isLeft)
import Data.Text (Text)
import Max.Browser.Profile (filterProfileState)
import Test.Hspec

spec :: Spec
spec = describe "explicit browser profile state" $ do
  it "copies only the consented origin and narrows parent-domain cookies to its host" $ do
    let state = storage [cookie ".example.com", cookie "other.test", cookie "notexample.com"] [origin "https://app.example.com", origin "https://other.test"]
    filterProfileState "https://app.example.com" state
      `shouldBe` Right (storage [cookie "app.example.com"] [origin "https://app.example.com"])
  it "rejects URLs with credentials, paths, queries or insecure schemes" $ do
    mapM_
      (\url -> filterProfileState url (storage [] []) `shouldSatisfy` isLeft)
      ["http://example.com", "https://user:pass@example.com", "https://example.com/path", "https://example.com/?token=secret", "file:///tmp/state"]
  it "does not treat a suffix lookalike as the cookie's domain" $
    filterProfileState "https://notexample.com" (storage [cookie ".example.com"] []) `shouldBe` Right (storage [] [])

storage :: [Value] -> [Value] -> Value
storage cookies origins = object ["storage" .= object ["cookies" .= cookies, "origins" .= origins]]

cookie :: Text -> Value
cookie domain = object ["domain" .= domain, "name" .= ("fixture" :: Text), "value" .= ("not-a-secret" :: Text)]

origin :: Text -> Value
origin url = object ["origin" .= url, "localStorage" .= ([] :: [Value])]
