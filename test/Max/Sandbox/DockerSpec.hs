module Max.Sandbox.DockerSpec (spec) where

import Max.Sandbox.Docker (stripAnsi, wrapPackages)
import Test.Hspec

spec :: Spec
spec = do
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

    it "warms the store on a silenced pass before the real run" $
      wrapPackages ["eza"] "eza -al"
        `shouldBe` "nix shell 'nixpkgs#eza' -c true >/dev/null 2>&1; \
                   \nix shell 'nixpkgs#eza' -c sh -c 'eza -al'"
