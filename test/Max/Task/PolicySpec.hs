module Max.Task.PolicySpec (spec) where

import Max.Task.Policy
import Test.Hspec

spec :: Spec
spec = describe "task policy" $ do
  it "uses the configured foreground tool and activation limits" $ do
    frontendToolLimit `shouldBe` 600
    frontendDeadlineSeconds `shouldBe` 3600
    frontendLeaseSeconds `shouldSatisfy` (> frontendDeadlineSeconds)
