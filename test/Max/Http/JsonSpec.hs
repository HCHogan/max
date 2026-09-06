module Max.Http.JsonSpec (spec) where

import Max.Http.Json (defaultRetryDelaysSecs, replyRetryDelaysSecs, retryableStatus)
import Test.Hspec

spec :: Spec
spec = do
  describe "retryableStatus" $ do
    it "retries rate-limit and timeout-ish statuses" $ do
      retryableStatus 408 `shouldBe` True
      retryableStatus 429 `shouldBe` True

    it "retries every server-side status" $ do
      retryableStatus 500 `shouldBe` True
      retryableStatus 502 `shouldBe` True
      retryableStatus 503 `shouldBe` True
      retryableStatus 529 `shouldBe` True

    it "never retries client errors we caused" $ do
      retryableStatus 400 `shouldBe` False
      retryableStatus 401 `shouldBe` False
      retryableStatus 403 `shouldBe` False
      retryableStatus 404 `shouldBe` False
      retryableStatus 422 `shouldBe` False

    it "never retries success" $ do
      retryableStatus 200 `shouldBe` False
      retryableStatus 600 `shouldBe` False

  describe "defaultRetryDelaysSecs" $
    it "is a short, bounded schedule" $ do
      length defaultRetryDelaysSecs `shouldBe` 2
      sum defaultRetryDelaysSecs `shouldSatisfy` (<= 15)

  describe "replyRetryDelaysSecs" $
    it "waits out a relay outage but stays bounded under drain" $ do
      sum replyRetryDelaysSecs `shouldSatisfy` (>= 120)
      sum replyRetryDelaysSecs `shouldSatisfy` (<= 300)
