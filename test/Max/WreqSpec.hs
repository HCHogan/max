module Max.WreqSpec (spec) where

import Max.Wreq (defaultRetryDelaysSecs, replyRetryDelaysSecs, retryableStatus, retryableStatusBody)
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

  describe "retryableStatusBody" $ do
    -- The exact bodies production saw during the 2026-07 relay
    -- outages: upstream failures wrapped in a 4xx by the gateway.
    it "retries a relay-wrapped 4xx that blames an upstream" $ do
      retryableStatusBody
        400
        "{\"error\":{\"message\":\"Error from provider (Console Go): Upstream request failed\",\"type\":\"invalid_request_error\"}}"
        `shouldBe` True
      retryableStatusBody 429 "Provider rate limit exceeded" `shouldBe` True

    it "still fails fast on a genuine bad request" $ do
      retryableStatusBody 400 "{\"error\":{\"message\":\"messages: field required\"}}" `shouldBe` False
      retryableStatusBody 401 "Invalid API key" `shouldBe` False
      retryableStatusBody 422 "unknown parameter: reasoning_effort" `shouldBe` False

    it "keeps every plain-status verdict" $ do
      retryableStatusBody 503 "" `shouldBe` True
      retryableStatusBody 200 "" `shouldBe` False

  describe "defaultRetryDelaysSecs" $
    it "is a short, bounded schedule" $ do
      length defaultRetryDelaysSecs `shouldBe` 2
      sum defaultRetryDelaysSecs `shouldSatisfy` (<= 15)

  describe "replyRetryDelaysSecs" $
    it "waits out a relay outage but stays bounded under drain" $ do
      -- Long enough to cover minutes-scale relay windows, short
      -- enough that a doomed turn resolves well inside the systemd
      -- stop timeout once the drain gives up on it.
      sum replyRetryDelaysSecs `shouldSatisfy` (>= 120)
      sum replyRetryDelaysSecs `shouldSatisfy` (<= 300)
