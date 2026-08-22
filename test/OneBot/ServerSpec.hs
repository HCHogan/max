module OneBot.ServerSpec (spec) where

import OneBot.Server (clearClientGeneration)
import Test.Hspec

spec :: Spec
spec = describe "OneBot client publication" $ do
  it "lets an owner clear its own generation" $
    clearClientGeneration 1 (Just (1, "old" :: String))
      `shouldBe` Nothing

  it "does not let a stale connection clear its replacement" $
    clearClientGeneration 1 (Just (2, "new" :: String))
      `shouldBe` Just (2, "new")
