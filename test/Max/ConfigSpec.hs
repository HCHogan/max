module Max.ConfigSpec (spec) where

import Max.Admin (AdminConfig (..))
import Max.Config
import Max.Http.Json (replyRetryDelaysSecs)
import Max.Task.Policy (frontendDeadlineSeconds, taskDeadlineSeconds)
import System.Environment (withArgs)
import System.IO (hClose, hPutStr)
import System.IO.Temp (withSystemTempFile)
import Test.Hspec

spec :: Spec
spec = describe "startup configuration" $ do
  it "loads the optional webhook base and rejects embedded credentials" $ do
    config <- withArgs ["--llm-api-key", "test-key", "--admin-port", "7700", "--webhook-base-url", "https://max.example/"] loadConfig
    fmap (.acWebhookBaseUrl) config.admin `shouldBe` Just (Just "https://max.example")
    withArgs ["--llm-api-key", "test-key", "--admin-port", "7700", "--webhook-base-url", "https://user:secret@max.example"] loadConfig
      `shouldThrow` anyIOException
  it "leaves room for slow-model attempts inside phase and task deadlines" $
    withArgs ["--llm-api-key", "test-key"] $ do
      config <- loadConfig
      explicit <- withArgs ["--llm-api-key", "test-key", "--llm-timeout-seconds", "1800"] loadConfig
      (config.llm == explicit.llm) `shouldBe` True
      let retryBudget = 1800 * (1 + length replyRetryDelaysSecs) + sum replyRetryDelaysSecs
      config.turnSilenceSeconds `shouldSatisfy` (> retryBudget)
      frontendDeadlineSeconds `shouldSatisfy` (> config.turnSilenceSeconds)
      taskDeadlineSeconds `shouldSatisfy` (> config.turnSilenceSeconds)
  it "preserves explicit model and watchdog timeouts" $
    withSystemTempFile "max-timeouts.yaml" $ \path handle -> do
      hPutStr handle "turn_silence_seconds: 600\nllm:\n  default: main\n  profiles:\n    main:\n      api_key: test-key\n      timeout_seconds: 120\n"
      hClose handle
      withArgs ["--config-file", path] $ do
        config <- loadConfig
        config.turnSilenceSeconds `shouldBe` 600
        explicit <- withArgs ["--config-file", path, "--llm-timeout-seconds", "120"] loadConfig
        (config.llm == explicit.llm) `shouldBe` True
  it "accepts browser options and rejects invalid retention settings" $
    withArgs ["--llm-api-key", "test-key", "--browser-state-key-file", "test-browser.key", "--browser-idle-seconds", "3600", "--browser-grace-seconds", "60"] $ do
      config <- loadConfig
      config.browserStateKeyFile `shouldBe` "test-browser.key"
      config.browserIdleSeconds `shouldBe` 3600
      config.browserGraceSeconds `shouldBe` 60
      validateConfig (config {browserIdleSeconds = 0, browserGraceSeconds = -1}) `shouldContain` ["browser.idle_seconds", "browser.grace_seconds"]
  it "rejects an invalid worker count at startup" $
    withArgs ["--llm-api-key", "test-key", "--image-workers", "0"] $
      loadConfig `shouldThrow` anyIOException
  it "rejects incomplete Matrix settings" $
    withArgs ["--llm-api-key", "test-key", "--matrix-homeserver", "https://matrix.example.test"] $
      loadConfig `shouldThrow` anyIOException
  it "rejects incomplete iMessage settings" $
    withArgs ["--llm-api-key", "test-key", "--imessage-bridge-url", "http://127.0.0.1:12345"] $
      loadConfig `shouldThrow` anyIOException
  it "rejects unknown model references" $
    withArgs ["--llm-api-key", "test-key"] $ do
      config <- loadConfig
      validateConfig (config {memoryExtractProfile = Just "missing-profile"}) `shouldContain` ["memory.extract_profile"]
