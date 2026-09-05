module Max.ConfigReloadSpec (spec) where

import Max.Config
import OneBot.Server (ServerConfig (..))
import System.Environment (withArgs)
import Test.Hspec

spec :: Spec
spec = describe "reload candidate configuration" $ do
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
