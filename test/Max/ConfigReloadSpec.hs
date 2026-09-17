module Max.ConfigReloadSpec (spec) where

import Max.Config
import Max.Http.Json (replyRetryDelaysSecs)
import Max.Task.Policy (frontendDeadlineSeconds, taskDeadlineSeconds)
import OneBot.Server (ServerConfig (..))
import System.Environment (withArgs)
import System.IO (hClose, hPutStr)
import System.IO.Temp (withSystemTempFile)
import Test.Hspec

spec :: Spec
spec = describe "reload candidate configuration" $ do
  it "leaves room for all slow-model attempts inside the phase and task deadlines" $
    withArgs ["--llm-api-key", "test-key"] $ do
      config <- loadConfig
      -- Compare the resolved catalog without exposing its private transport
      -- settings. An explicit default must leave the effective config unchanged.
      explicit <- withArgs ["--llm-api-key", "test-key", "--llm-timeout-seconds", "1800"] loadConfig
      configChanges config explicit `shouldBe` []
      let retryBudget = 1800 * (1 + length replyRetryDelaysSecs) + sum replyRetryDelaysSecs
      config.turnSilenceSeconds `shouldSatisfy` (> retryBudget)
      frontendDeadlineSeconds `shouldSatisfy` (> config.turnSilenceSeconds)
      taskDeadlineSeconds `shouldSatisfy` (> config.turnSilenceSeconds)
  it "preserves explicit model and watchdog timeout overrides on reload" $
    withSystemTempFile "max-timeouts.yaml" $ \path handle -> do
      hPutStr handle "turn_silence_seconds: 600\nllm:\n  default: main\n  profiles:\n    main:\n      api_key: test-key\n      timeout_seconds: 120\n"
      hClose handle
      withArgs ["--config-file", path] $ do
        config <- loadConfig
        config.turnSilenceSeconds `shouldBe` 600
        explicit <- withArgs ["--config-file", path, "--llm-timeout-seconds", "120"] loadConfig
        configChanges config explicit `shouldBe` []
        updated <- withArgs ["--config-file", path, "--llm-timeout-seconds", "1800", "--turn-silence-seconds", "14400"] loadConfig
        configChanges config updated `shouldBe` [ConfigChange "turn_silence_seconds" DispatchHot, ConfigChange "llm" DispatchHot]
  it "accepts browser options through the startup parser and its metadata checks" $
    withArgs ["--llm-api-key", "test-key", "--browser-state-key-file", "test-browser.key", "--browser-idle-seconds", "3600", "--browser-grace-seconds", "60"] $ do
      config <- loadConfig
      config.browserStateKeyFile `shouldBe` "test-browser.key"
      config.browserIdleSeconds `shouldBe` 3600
      config.browserGraceSeconds `shouldBe` 60
  it "classifies browser retention and key changes as restart-required and validates them" $
    withArgs ["--llm-api-key", "test-key"] $ do
      Right base <- loadConfigCandidate
      let candidate = base {browserStateKeyFile = "not-a-secret-path", browserIdleSeconds = 3600, browserGraceSeconds = 0}
      configChanges base candidate
        `shouldBe` [ConfigChange "browser.state_key_file" RestartRequired, ConfigChange "browser.idle_seconds" RestartRequired, ConfigChange "browser.grace_seconds" RestartRequired]
      validateConfig (base {browserIdleSeconds = 0, browserGraceSeconds = -1}) `shouldContain` ["browser.idle_seconds", "browser.grace_seconds"]
  it "returns validation failure instead of exiting the process" $
    withArgs ["--llm-api-key", "test-key", "--image-workers", "0"] $ do
      loadConfigCandidate >>= \case
        Left err -> err `shouldBe` ConfigValidationFailed 1
        Right _ -> expectationFailure "invalid candidate was accepted"

  it "reports incomplete Matrix settings through structured validation" $
    withArgs ["--llm-api-key", "test-key", "--matrix-homeserver", "https://matrix.example.test"] $ do
      result <- loadConfigCandidate
      case result of
        Left (ConfigValidationFailed count) -> count `shouldSatisfy` (> 0)
        _ -> expectationFailure "expected structured Matrix validation failure"

  it "reports incomplete iMessage settings through structured validation" $
    withArgs ["--llm-api-key", "test-key", "--imessage-bridge-url", "http://127.0.0.1:12345"] $ do
      result <- loadConfigCandidate
      case result of
        Left (ConfigValidationFailed count) -> count `shouldSatisfy` (> 0)
        _ -> expectationFailure "expected structured iMessage validation failure"

  it "returns a structured load failure for a missing explicit file" $
    withArgs ["--llm-api-key", "test-key", "--config-file", "/definitely/missing/max.yaml"] $ do
      loadConfigCandidate >>= (`shouldSatisfy` isLeft)

  it "classifies hot, handoff, and restart fields centrally without values" $
    withArgs ["--llm-api-key", "test-key"] $ do
      Right base <- loadConfigCandidate
      let candidate =
            base
              { persona = "do-not-leak-this-persona",
                imageWorkers = base.imageWorkers + 1,
                server = base.server {port = base.server.port + 1}
              }
          changes = configChanges base candidate
      changes
        `shouldBe` [ ConfigChange "server.port" RestartRequired,
                     ConfigChange "image_workers" WorkerHandoff,
                     ConfigChange "persona" DispatchHot
                   ]
      show changes `shouldNotContain` "do-not-leak-this-persona"

  it "validates cross-field model references before publication" $
    withArgs ["--llm-api-key", "test-key"] $ do
      Right base <- loadConfigCandidate
      validateConfig (base {memoryExtractProfile = Just "missing-profile"})
        `shouldContain` ["memory.extract_profile"]
  where
    isLeft = \case Left _ -> True; Right _ -> False
