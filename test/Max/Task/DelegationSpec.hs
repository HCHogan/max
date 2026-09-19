module Max.Task.DelegationSpec (spec) where

import Data.Aeson
import Data.Either (isLeft)
import Data.Text qualified as T
import Max.Task.Delegation
import Max.Task.Types (profileName, taskProfileNames)
import Test.Hspec

spec :: Spec
spec = describe "workflow agent request contract" $ do
  it "offers three profiles and decodes legacy operations workflows as sandbox" $ do
    taskProfileNames `shouldBe` ["research", "browser", "sandbox"]
    let request profile = object ["objective" .= ("SSH audit" :: T.Text), "profile" .= (profile :: T.Text)]
    Right legacy <- pure (parseAgentRequest (request "operations"))
    Right current <- pure (parseAgentRequest (request "sandbox"))
    legacy `shouldBe` current
    toJSON legacy `shouldBe` toJSON current
    profileName legacy.profile `shouldBe` "sandbox"

  it "normalizes omitted inputs and objective whitespace" $ do
    Right first <- pure (parseAgentRequest (object ["objective" .= (" investigate " :: T.Text), "profile" .= ("research" :: T.Text)]))
    Right second <- pure (parseAgentRequest (object ["inputs" .= Null, "objective" .= ("investigate" :: T.Text), "profile" .= ("research" :: T.Text)]))
    first `shouldBe` second
  it "rejects authority fields, unknown profiles, oversized inputs and open schema vocabulary" $ do
    mapM_
      (\input -> parseAgentRequest input `shouldSatisfy` isLeft)
      [ object ["objective" .= ("inspect" :: T.Text), "profile" .= ("research" :: T.Text), "grants" .= object []],
        object ["objective" .= ("inspect" :: T.Text), "profile" .= ("administrator" :: T.Text)],
        object ["objective" .= ("inspect" :: T.Text), "profile" .= ("research" :: T.Text), "inputs" .= T.replicate 65536 "x"],
        object ["objective" .= ("inspect" :: T.Text), "profile" .= ("research" :: T.Text), "output_contract" .= object ["type" .= ("string" :: T.Text), "pattern" .= (".*" :: T.Text)]]
      ]
