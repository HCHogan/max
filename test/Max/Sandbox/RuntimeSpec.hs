module Max.Sandbox.RuntimeSpec (spec) where

import Control.Exception (bracket)
import Max.Sandbox.Runtime (inspectContainerPolicy, stripAnsi, wrapPackages)
import System.Directory (Permissions (..), getPermissions, setPermissions)
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

spec :: Spec
spec = do
  describe "container network adoption" $ do
    it "adopts only the current policy on exactly the operator network" $
      withRuntimeInspection "printf '6 max-sandbox 1\\n'" $
        inspectContainerPolicy "fixture" `shouldReturn` True
    it "rejects an otherwise current container connected to a second network" $
      withRuntimeInspection "printf '6 max-sandbox 2\\n'" $
        inspectContainerPolicy "fixture" `shouldReturn` False
    it "rejects a replaced network even when its policy label is current" $
      withRuntimeInspection "printf '6 bridge 1\\n'" $
        inspectContainerPolicy "fixture" `shouldReturn` False
    it "rebuilds an old disconnected shell" $
      withRuntimeInspection "printf '4 none 0\\n'" $
        inspectContainerPolicy "fixture" `shouldReturn` False
    it "does not adopt when runtime inspection fails" $
      withRuntimeInspection "exit 1" $
        inspectContainerPolicy "fixture" `shouldReturn` False

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

withRuntimeInspection :: String -> IO a -> IO a
withRuntimeInspection output action = withSystemTempDirectory "max-runtime-policy" $ \directory -> do
  let command = directory </> "max-runtime"
  writeFile command ("#!/bin/sh\n" <> output <> "\n")
  permissions <- getPermissions command
  setPermissions command (permissions {executable = True})
  bracket (lookupEnv "PATH") (maybe (unsetEnv "PATH") (setEnv "PATH")) $ \previous -> do
    setEnv "PATH" (directory <> maybe "" (':' :) previous)
    action
