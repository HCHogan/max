{-# LANGUAGE OverloadedStrings #-}

-- |
-- The fixtures here are shaped after CLIProxyAPI's own
-- @buildAuthFileEntry@, not after a live capture: the endpoint needs a
-- management key we don't hold in CI, and the field list is what the
-- other project's source says it emits.  That makes these tests a
-- statement about the contract we coded against — which is exactly
-- what would silently rot when the proxy is upgraded, so pinning it is
-- the point.
module Max.CliProxySpec (spec) where

import Data.Aeson (Value (..))
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy.Char8 qualified as LBS
import Max.CliProxy
import Test.Hspec

-- | A healthy ChatGPT credential, id-token claims and all.
healthy :: LBS.ByteString
healthy =
  "{\"files\":[{\
  \\"id\":\"codex-hank\",\
  \\"auth_index\":\"0\",\
  \\"name\":\"codex-hank.json\",\
  \\"type\":\"codex\",\
  \\"provider\":\"codex\",\
  \\"label\":\"main\",\
  \\"status\":\"active\",\
  \\"disabled\":false,\
  \\"unavailable\":false,\
  \\"success\":1842,\
  \\"failed\":17,\
  \\"email\":\"hank@example.com\",\
  \\"recent_requests\":[\
    \{\"time\":\"10:20-10:30\",\"success\":3,\"failed\":0},\
    \{\"time\":\"10:30-10:40\",\"success\":5,\"failed\":1}],\
  \\"id_token\":{\
    \\"chatgpt_account_id\":\"acct_1\",\
    \\"plan_type\":\"pro\",\
    \\"chatgpt_subscription_active_until\":\"2026-09-01T00:00:00Z\"}}]}"

-- | The same credential after Codex answered @usage_limit_reached@.
spent :: LBS.ByteString
spent =
  "{\"files\":[{\
  \\"id\":\"codex-hank\",\
  \\"provider\":\"codex\",\
  \\"status\":\"error\",\
  \\"status_message\":\"quota exceeded\",\
  \\"disabled\":false,\
  \\"unavailable\":true,\
  \\"next_retry_after\":\"2026-08-01T18:30:00+08:00\",\
  \\"success\":1842,\
  \\"failed\":18,\
  \\"recent_requests\":[]}]}"

one :: LBS.ByteString -> Credential
one raw = case parseCredentials raw of
  Right [c] -> c
  other -> error ("fixture did not yield one credential: " <> show other)

spec :: Spec
spec = do
  describe "parseCredentials" $ do
    it "reads a healthy credential and its plan claims" $ do
      let c = one healthy
      c.crId `shouldBe` "codex-hank"
      c.crProvider `shouldBe` "codex"
      c.crStatus `shouldBe` "active"
      c.crEmail `shouldBe` Just "hank@example.com"
      c.crPlanType `shouldBe` Just "pro"
      c.crSuccess `shouldBe` 1842
      c.crFailed `shouldBe` 17
      map (.bkSuccess) c.crRecent `shouldBe` [3, 5]

    -- The distinction the endpoint exists to make: "up" and "has a
    -- credential" are not the same sentence.
    it "reads an exhausted credential, including when it comes back" $ do
      let c = one spent
      c.crUnavailable `shouldBe` True
      c.crStatusMessage `shouldBe` Just "quota exceeded"
      show c.crNextRetryAfter `shouldBe` "Just 2026-08-01 10:30:00 UTC"

    it "calls a healthy credential serving and a spent one not" $ do
      serving (one healthy) `shouldBe` True
      serving (one spent) `shouldBe` False

    -- Another project's JSON across an upgrade we don't control: a
    -- field that vanishes should cost one blank column, not the whole
    -- endpoint.
    it "survives an entry stripped to nothing but a provider" $ do
      case parseCredentials "{\"files\":[{\"provider\":\"gemini\"}]}" of
        Right [c] -> do
          c.crProvider `shouldBe` "gemini"
          c.crStatus `shouldBe` "unknown"
          c.crPlanType `shouldBe` Nothing
          serving c `shouldBe` True
        other -> expectationFailure ("expected one credential: " <> show other)

    it "reads an empty pool as an empty pool, not an error" $
      parseCredentials "{\"files\":[]}" `shouldBe` Right []

    it "reports unreadable json rather than throwing" $
      case parseCredentials "not json" of
        Left _ -> pure ()
        Right cs -> expectationFailure ("expected a decode error, got " <> show cs)

  describe "credentialJson" $
    -- The rollup is the endpoint's whole value-add over passthrough:
    -- a health check shouldn't have to sum an array to learn whether
    -- anything got through lately.
    it "totals the recent buckets and names their span" $ do
      case credentialJson (one healthy) of
        Object o -> case KM.lookup "recent" o of
          Just (Object r) -> do
            KM.lookup "success" r `shouldBe` Just (Number 8)
            KM.lookup "failed" r `shouldBe` Just (Number 1)
            KM.lookup "window_minutes" r `shouldBe` Just (Number 20)
          other -> expectationFailure ("expected a recent object: " <> show other)
        other -> expectationFailure ("expected an object: " <> show other)

  describe "managementUrl" $ do
    let at base = managementUrl (CliProxyConfig base "k") "/auth-files"

    it "hangs the management path off the server root" $
      at "http://127.0.0.1:8317"
        `shouldBe` "http://127.0.0.1:8317/v0/management/auth-files"

    -- The URL everyone has at hand is the LLM base URL, and the 404
    -- this would otherwise produce reads exactly like "remote
    -- management is switched off".
    it "tolerates the /v1 tail copied from an llm profile" $
      at "http://127.0.0.1:8317/v1"
        `shouldBe` "http://127.0.0.1:8317/v0/management/auth-files"

    it "tolerates a trailing slash" $
      at "http://127.0.0.1:8317/v1/"
        `shouldBe` "http://127.0.0.1:8317/v0/management/auth-files"
