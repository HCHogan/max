module Max.ConfigReloadSpec (spec) where

import Control.Exception (bracket)
import Max.Config
import Max.MaxOps.Types
import OneBot.Server (ServerConfig (..))
import System.Environment (lookupEnv, setEnv, unsetEnv, withArgs)
import System.IO (hClose, hPutStr)
import System.IO.Temp (withSystemTempFile)
import Test.Hspec

spec :: Spec
spec = describe "reload candidate configuration" $ do
  it "accepts native maxops environment options and an explicit empty allowlist" $
    withEnvironment "MAX_MAXOPS_ENABLED" "True" $
      withEnvironment "MAX_MAXOPS_TOKEN_FILE" "/run/credentials/max.service/maxops-token" $
        withEnvironment "MAX_MAXOPS_ALLOWED_GROUPS" "" $
          withArgs ["--llm-api-key", "fixture-key"] $ do
            config <- loadConfig
            config.maxops.mocEnabled `shouldBe` True
            config.maxops.mocAllowedGroups `shouldBe` []
  it "loads maxops group permissions from YAML and classifies them as hot reloadable" $
    withSystemTempFile "maxops.yaml" $ \path handle -> do
      hPutStr handle "maxops:\n  enabled: true\n  base_url: http://127.0.0.1:9721\n  token_file: /run/credentials/max.service/maxops-token\n  allowed_groups: [611798505]\n"
      hClose handle
      withArgs ["--llm-api-key", "fixture-key", "--config-file", path] $ do
        config <- loadConfig
        config.maxops `shouldBe` MaxOpsConfig True "http://127.0.0.1:9721" "/run/credentials/max.service/maxops-token" [611798505]
        let revoked = config {maxops = config.maxops {mocAllowedGroups = []}}
        configChanges config revoked `shouldBe` [ConfigChange "maxops" DispatchHot]
  it "rejects unsafe maxops endpoints, token paths, and non-group IDs" $ do
    let configured = MaxOpsConfig True "http://127.0.0.1:9721" "/run/maxops-token" [611798505]
    mapM_
      (\url -> validateMaxOpsConfig (configured {mocBaseUrl = url}) `shouldContain` ["maxops.base_url"])
      ["http://token@hub", "http://hub?token=secret", "http://hub#fragment", "file:///run/token", "not-a-url"]
    mapM_
      (\path -> validateMaxOpsConfig (configured {mocTokenFile = path}) `shouldContain` ["maxops.token_file"])
      ["", "relative-token", "/nix/store/leaked-token"]
    validateMaxOpsConfig (configured {mocAllowedGroups = [-1]}) `shouldContain` ["maxops.allowed_groups"]
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

withEnvironment :: String -> String -> IO a -> IO a
withEnvironment name value action = bracket (lookupEnv name) (maybe (unsetEnv name) (setEnv name)) $ \_ -> setEnv name value >> action
