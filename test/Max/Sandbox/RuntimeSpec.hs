module Max.Sandbox.RuntimeSpec (spec) where

import Control.Exception (bracket)
import Data.ByteString qualified as BS
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Max.Runtime.Protocol (sandboxPolicyVersion)
import Max.Sandbox.Runtime (classifyRead, inspectContainerPolicy, stripAnsi, wrapPackages)
import Max.Sandbox.Types (SandboxRead (..))
import System.Directory (Permissions (..), getPermissions, setPermissions)
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

spec :: Spec
spec = do
  describe "container network adoption" $ do
    it "adopts only the current policy on exactly the operator network" $
      withRuntimeInspection (current "max-sandbox 1") $
        inspectContainerPolicy "fixture" "max-sandbox" `shouldReturn` True
    it "rejects an otherwise current container connected to a second network" $
      withRuntimeInspection (current "max-sandbox 2") $
        inspectContainerPolicy "fixture" "max-sandbox" `shouldReturn` False
    it "rejects a replaced network even when its policy label is current" $
      withRuntimeInspection (current "bridge 1") $
        inspectContainerPolicy "fixture" "max-sandbox" `shouldReturn` False
    it "rebuilds an old disconnected shell" $
      withRuntimeInspection "printf '4 none 0\\n'" $
        inspectContainerPolicy "fixture" "max-sandbox" `shouldReturn` False
    it "does not adopt when runtime inspection fails" $
      withRuntimeInspection "exit 1" $
        inspectContainerPolicy "fixture" "max-sandbox" `shouldReturn` False

  describe "operations network adoption" $ do
    it "requires the requested operations network" $
      withRuntimeInspection (current "maxops 1") $
        inspectContainerPolicy "fixture" "maxops" `shouldReturn` True
    it "does not adopt an operations container as a public sandbox" $
      withRuntimeInspection (current "maxops 1") $
        inspectContainerPolicy "fixture" "max-sandbox" `shouldReturn` False

  describe "file reads" $ do
    it "returns text, marking a read that reached its limit" $ do
      classifyRead 5 "hello" `shouldBe` SandboxRead (Just "hello") 5 False
      classifyRead 4 "hello" `shouldBe` SandboxRead (Just "hell") 4 True
    it "drops a character cut by the limit instead of calling the file binary" $ do
      let bytes = TE.encodeUtf8 "报告"
      classifyRead 4 bytes `shouldBe` SandboxRead (Just "报") 4 True
    it "reports binary content by size only" $ do
      classifyRead 16 (BS.pack [0x89, 0x50, 0x4e, 0x47, 0, 1]) `shouldBe` SandboxRead Nothing 6 False
      classifyRead 16 (BS.pack [0xff, 0xfe, 0x41]) `shouldBe` SandboxRead Nothing 3 False

  describe "stripAnsi" $ do
    it "drops SGR colour codes" $
      stripAnsi "\ESC[101m red \ESC[m done" `shouldBe` " red  done"

    it "drops cursor-movement CSI codes (fastfetch layout)" $
      stripAnsi "\ESC[25Chost\ESC[11A\ESC[1Gx" `shouldBe` "hostx"

    it "drops an OSC title sequence terminated by BEL" $
      stripAnsi "\ESC]0;my title\BELhi" `shouldBe` "hi"

    it "drops leftover carriage returns but keeps newlines and tabs" $
      stripAnsi "a\r\nb\tc" `shouldBe` "a\nb\tc"

    it "leaves plain text untouched" $
      stripAnsi "just text 123" `shouldBe` "just text 123"

  describe "wrapPackages" $ do
    it "returns the command unchanged with no packages" $
      wrapPackages [] "ls -al" `shouldBe` "ls -al"

    it "activates store paths already realised by the restricted helper" $
      wrapPackages ["/nix/store/abc-eza"] "eza -al"
        `shouldBe` "export PATH='/nix/store/abc-eza/bin':\"$PATH\"; exec sh -c 'eza -al'"

    it "combines multiple outputs and preserves shell quoting" $
      wrapPackages ["/nix/store/abc-qpdf", "/nix/store/def-python-env"] "python3 -c 'import openpyxl'"
        `shouldBe` "export PATH='/nix/store/abc-qpdf/bin:/nix/store/def-python-env/bin':\"$PATH\"; exec sh -c 'python3 -c '\\''import openpyxl'\\'''"

-- | A policy line claiming the current contract for the given network.
current :: String -> String
current rest = "printf '" <> T.unpack sandboxPolicyVersion <> " " <> rest <> "\\n'"

withRuntimeInspection :: String -> IO a -> IO a
withRuntimeInspection output action = withSystemTempDirectory "max-runtime-policy" $ \directory -> do
  let command = directory </> "max-runtime"
  writeFile command ("#!/bin/sh\n" <> output <> "\n")
  permissions <- getPermissions command
  setPermissions command (permissions {executable = True})
  bracket (lookupEnv "PATH") (maybe (unsetEnv "PATH") (setEnv "PATH")) $ \previous -> do
    setEnv "PATH" (directory <> maybe "" (':' :) previous)
    action
