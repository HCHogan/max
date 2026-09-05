module Max.Task.PolicySpec (spec) where

import Data.Foldable (for_)
import Max.Task.Policy
import Test.Hspec

spec :: Spec
spec = describe "task policy" $ do
  it "relaxes foreground quotas fivefold" $ do
    frontendToolLimit `shouldBe` 30
    frontendDeadlineSeconds `shouldBe` 375
  for_ ["HTTP 429 busy", "HTTP 503 unavailable", "HTTP response timed out", "HTTP connection failed: reset"] $ \detail ->
    it ("retries temporary failures: " <> show detail) $
      retryableFailure detail `shouldBe` True
  for_ ["HTTP 401 unauthorized", "HTTP 403 denied", "HTTP 400 invalid request", "task budget exhausted", "cancelled"] $ \detail ->
    it ("does not retry permanent failures: " <> show detail) $
      retryableFailure detail `shouldBe` False
