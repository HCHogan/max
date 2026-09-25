module Max.ConfigSpec (spec) where

import Data.Foldable (for_)
import Max.Admin (AdminConfig (..))
import Max.Config
import Max.Http.Json (replyRetryDelaysSecs)
import Max.ModelCatalog
import Max.Task.Policy (frontendDeadlineSeconds, taskDeadlineSeconds)
import Max.Tools.Search (SearchConfig (..))
import System.Environment (withArgs)
import System.IO (hClose, hPutStr)
import System.IO.Temp (withSystemTempFile)
import Test.Hspec

spec :: Spec
spec = describe "startup configuration" $ do
  it "enables free Exa search without credentials and accepts an optional fallback key" $ do
    config <- withArgs ["--llm-api-key", "test-key", "--exa-api-key", ""] loadConfig
    config.search `shouldBe` Just (SearchConfig Nothing 5 30)
    keyed <- withArgs ["--llm-api-key", "test-key", "--exa-api-key", " exa-test "] loadConfig
    keyed.search `shouldBe` Just (SearchConfig (Just "exa-test") 5 30)
    disabled <- withArgs ["--llm-api-key", "test-key", "--search-enabled", "False"] loadConfig
    disabled.search `shouldBe` Nothing
  it "reads Exa search settings from YAML and rejects invalid budgets" $
    withSystemTempFile "max-search.yaml" $ \path handle -> do
      hPutStr handle "llm:\n  default: main\n  profiles:\n    main:\n      api_key: test-key\nsearch:\n  enabled: true\n  exa_api_key: exa-test\n  max_results: 3\n  timeout_seconds: 15\n"
      hClose handle
      config <- withArgs ["--config-file", path] loadConfig
      config.search `shouldBe` Just (SearchConfig (Just "exa-test") 3 15)
      for_ [["--search-max-results", "0"], ["--search-max-results", "11"], ["--search-timeout-seconds", "0"], ["--search-timeout-seconds", "301"]] $ \flags ->
        withArgs (["--config-file", path] <> flags) loadConfig `shouldThrow` anyIOException
  it "derives all context limits from the single combined-window CLI option" $ do
    config <- withArgs ["--llm-api-key", "test-key", "--llm-context-window", "262144", "--llm-multimodal", "True"] loadConfig
    fmap (.contextLimits) (lookupModelCapabilities (defaultModelName config.llm) config.llm)
      `shouldBe` Just (ContextLimits 229376 32768 32768 32768 Nothing Nothing)
  it "reads context_window from a profile and applies an output override safely" $
    withSystemTempFile "max-window.yaml" $ \path handle -> do
      hPutStr handle "llm:\n  default: main\n  profiles:\n    main:\n      api_key: test-key\n      context_window: 262144\n      multimodal: true\n"
      hClose handle
      config <- withArgs ["--config-file", path, "--llm-max-tokens", "8192"] loadConfig
      fmap (.contextLimits) (lookupModelCapabilities "main" config.llm)
        `shouldBe` Just (ContextLimits 253952 8192 32768 32768 Nothing Nothing)
  it "keeps legacy input-only configurations compatible" $ do
    config <- withArgs ["--llm-api-key", "test-key", "--llm-max-input-tokens", "65536", "--llm-max-tokens", "4096"] loadConfig
    fmap (.contextLimits) (lookupModelCapabilities (defaultModelName config.llm) config.llm)
      `shouldBe` Just (ContextLimits 65536 4096 0 16384 Nothing Nothing)
  it "validates the final reserves after applying explicit provider overrides" $ do
    config <- withArgs ["--llm-api-key", "test-key", "--llm-context-window", "262144", "--llm-max-tokens", "250000", "--llm-tool-round-reserve", "0", "--llm-attachment-reserve", "0"] loadConfig
    fmap (.contextLimits) (lookupModelCapabilities (defaultModelName config.llm) config.llm)
      `shouldBe` Just (ContextLimits 12144 250000 0 0 Nothing Nothing)
  it "carries a soft context budget and rejects one above the planning budget" $ do
    config <- withArgs ["--llm-api-key", "test-key", "--llm-context-window", "262144", "--llm-context-budget", "131072"] loadConfig
    fmap (.contextLimits) (lookupModelCapabilities (defaultModelName config.llm) config.llm)
      `shouldBe` Just (ContextLimits 229376 32768 0 32768 (Just 131072) Nothing)
    withArgs ["--llm-api-key", "test-key", "--llm-context-window", "262144", "--llm-context-budget", "196609"] loadConfig `shouldThrow` anyIOException
    withArgs ["--llm-api-key", "test-key", "--llm-context-window", "262144", "--llm-context-budget", "0"] loadConfig `shouldThrow` anyIOException
  it "reads a vision envelope and reserves input room for its media" $
    withSystemTempFile "max-vision.yaml" $ \path handle -> do
      hPutStr handle "llm:\n  default: main\n  profiles:\n    main:\n      api_key: test-key\n      context_window: 262144\n      multimodal: true\n      vision_tokens: 49152\n      vision_item_tokens: 16384\n"
      hClose handle
      config <- withArgs ["--config-file", path] loadConfig
      fmap (.contextLimits) (lookupModelCapabilities "main" config.llm)
        `shouldBe` Just (ContextLimits 229376 32768 49152 32768 Nothing (Just (VisionLimits 49152 16384 600 768 25165824)))
  it "reads per-profile prices, defaulting the cached price and currency" $ do
    let load fields = withSystemTempFile "max-prices.yaml" $ \path handle -> do
          hPutStr handle ("llm:\n  default: main\n  profiles:\n    main:\n      api_key: test-key\n" <> fields)
          hClose handle
          (.llm) <$> withArgs ["--config-file", path] loadConfig
    defaulted <- load "      price_input: 2\n      price_output: 8\n"
    explicit <- load "      price_input: 2\n      price_cached_input: 2\n      price_output: 8\n      price_currency: USD\n"
    discounted <- load "      price_input: 2\n      price_cached_input: 0.5\n      price_output: 8\n"
    unpriced <- load ""
    (defaulted == explicit) `shouldBe` True
    (defaulted == discounted) `shouldBe` False
    (defaulted == unpriced) `shouldBe` False
  it "rejects incomplete or negative prices" $
    for_
      [ "      price_input: 2\n",
        "      price_cached_input: 0.1\n",
        "      price_input: -1\n      price_output: 2\n",
        "      price_input: 1\n      price_output: 2\n      price_currency: \"  \"\n"
      ]
      $ \fields -> withSystemTempFile "max-prices.yaml" $ \path handle -> do
        hPutStr handle ("llm:\n  default: main\n  profiles:\n    main:\n      api_key: test-key\n" <> fields)
        hClose handle
        withArgs ["--config-file", path] loadConfig `shouldThrow` anyIOException
  it "rejects inconsistent vision envelopes" $
    for_
      [ "      multimodal: true\n      vision_tokens: 16384\n      vision_item_tokens: 32768\n",
        "      vision_tokens: 49152\n",
        "      multimodal: true\n      video_max_seconds: 600\n"
      ]
      $ \fields -> withSystemTempFile "max-vision.yaml" $ \path handle -> do
        hPutStr handle ("llm:\n  default: main\n  profiles:\n    main:\n      api_key: test-key\n" <> fields)
        hClose handle
        withArgs ["--config-file", path] loadConfig `shouldThrow` anyIOException
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
