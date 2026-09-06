module Max.Browser.StateSpec (spec) where

import Max.Browser.State
import Test.Hspec

spec :: Spec
spec = describe "browser ownership and recovery policy" $ do
  it "never treats process or revision changes as evidence that an uncertain action did not happen" $ do
    [decideAcquisition state True True True | state <- [Busy, Uncertain]]
      `shouldBe` replicate 2 (Left WorkspaceUnknown)
  it "requires explicit reset after revocation even with a fresh runtime" $ do
    decideAcquisition Revoked True True True `shouldBe` Left WorkspaceRevoked
  it "rejects revoked profile credentials before restoring a saved checkpoint" $ do
    decideAcquisition Hot False False True `shouldBe` Left ProfileRevoked
  it "distinguishes a specification reset from a process restoration" $ do
    decideAcquisition Hot True True True `shouldBe` Right ResetRevision
    decideAcquisition Hot True False True `shouldBe` Right RestoreRuntime
    decideAcquisition Hot True False False `shouldBe` Right ReuseWorkspace
