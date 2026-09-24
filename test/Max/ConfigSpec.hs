module Max.ConfigSpec (spec) where

import Max.Admin (AdminConfig (..))
import Max.Config
import Max.Http.Json (replyRetryDelaysSecs)
import Max.ModelCatalog
import Max.Task.Policy (frontendDeadlineSeconds, taskDeadlineSeconds)
import System.Environment (withArgs)
import System.IO (hClose, hPutStr)
import System.IO.Temp (withSystemTempFile)
import Test.Hspec

spec :: Spec
spec = describe "startup configuration" $ do
  it "derives all context limits from the single combined-window CLI option" $ do
    config <- withArgs ["--llm-api-key", "test-key", "--llm-context-window", "262144", "--llm-multimodal", "True"] loadConfig
    fmap (.contextLimits) (lookupModelCapabilities (defaultModelName config.llm) config.llm)
      `shouldBe` Just (ContextLimits 229376 32768 32768 32768 Nothing)
  it "reads context_window from a profile and applies an output override safely" $
    withSystemTempFile "max-window.yaml" $ \path handle -> do
      hPutStr handle "llm:\n  default: main\n  profiles:\n    main:\n      api_key: test-key\n      context_window: 262144\n      multimodal: true\n"
      hClose handle
      config <- withArgs ["--config-file", path, "--llm-max-tokens", "8192"] loadConfig
      fmap (.contextLimits) (lookupModelCapabilities "main" config.llm)
        `shouldBe` Just (ContextLimits 253952 8192 32768 32768 Nothing)
  it "keeps legacy input-only configurations compatible" $ do
    config <- withArgs ["--llm-api-key", "test-key", "--llm-max-input-tokens", "65536", "--llm-max-tokens", "4096"] loadConfig
    fmap (.contextLimits) (lookupModelCapabilities (defaultModelName config.llm) config.llm)
      `shouldBe` Just (ContextLimits 65536 4096 0 16384 Nothing)
  it "validates the final reserves after applying explicit provider overrides" $ do
    config <- withArgs ["--llm-api-key", "test-key", "--llm-context-window", "262144", "--llm-max-tokens", "250000", "--llm-tool-round-reserve", "0", "--llm-attachment-reserve", "0"] loadConfig
    fmap (.contextLimits) (lookupModelCapabilities (defaultModelName config.llm) config.llm)
      `shouldBe` Just (ContextLimits 12144 250000 0 0 Nothing)
  it "carries a soft context budget and rejects one above the planning budget" $ do
    config <- withArgs ["--llm-api-key", "test-key", "--llm-context-window", "262144", "--llm-context-budget", "131072"] loadConfig
    fmap (.contextLimits) (lookupModelCapabilities (defaultModelName config.llm) config.llm)
      `shouldBe` Just (ContextLimits 229376 32768 0 32768 (Just 131072))
    withArgs ["--llm-api-key", "test-key", "--llm-context-window", "262144", "--llm-context-budget", "196609"] loadConfig `shouldThrow` anyIOException
    withArgs ["--llm-api-key", "test-key", "--llm-context-window", "262144", "--llm-context-budget", "0"] loadConfig `shouldThrow` anyIOException
  it "rejects mixed total/input settings, impossible output, and exhausted reserves" $ do
    let invalid flags = withArgs (["--llm-api-key", "test-key", "--llm-context-window", "262144"] <> flags) loadConfig `shouldThrow` anyIOException
    invalid ["--llm-max-input-tokens", "262144"]
    invalid ["--llm-max-tokens", "262144"]
    invalid ["--llm-tool-round-reserve", "229376"]
    invalid ["--llm-attachment-reserve", "-1"]
    withArgs ["--llm-api-key", "test-key", "--llm-context-window", "0"] loadConfig `shouldThrow` anyIOException
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
