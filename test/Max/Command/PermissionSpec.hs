module Max.Command.PermissionSpec (spec) where

import Max.Command.Permission (PermTier (..), requiredCapability, tierSatisfied)
import Max.Command.Types (Command (..))
import Test.Hspec

spec :: Spec
spec = do
  describe "requiredCapability" $ do
    it "gates owner-tier switches" $ do
      requiredCapability (ModelSet "x") `shouldBe` Just ("model", TierOwner)
      requiredCapability (DebugSet Nothing) `shouldBe` Just ("debug", TierOwner)
      requiredCapability (StickerBan "ab") `shouldBe` Just ("sticker", TierOwner)
      requiredCapability (ProactiveSet (Just True)) `shouldBe` Just ("proactive", TierOwner)
      requiredCapability KillAll `shouldBe` Just ("kill-all", TierOwner)

    it "gates group-admin-tier state changes" $ do
      requiredCapability (PersonaSet "猫") `shouldBe` Just ("persona", TierGroupAdmin)
      requiredCapability PersonaClear `shouldBe` Just ("persona", TierGroupAdmin)
      requiredCapability Clear `shouldBe` Just ("clear", TierGroupAdmin)
      requiredCapability Unclear `shouldBe` Just ("clear", TierGroupAdmin)
      requiredCapability (Kill "t1") `shouldBe` Just ("kill", TierGroupAdmin)

    it "gates granting itself at group-admin tier" $ do
      requiredCapability (Grant 1 "persona" False False) `shouldBe` Just ("grant", TierGroupAdmin)
      requiredCapability (Revoke 1 "persona" False) `shouldBe` Just ("grant", TierGroupAdmin)
      requiredCapability (Perms Nothing) `shouldBe` Nothing

    it "leaves queries and own-scope commands open" $ do
      requiredCapability (Help Nothing) `shouldBe` Nothing
      requiredCapability ModelShow `shouldBe` Nothing
      requiredCapability ModelList `shouldBe` Nothing
      requiredCapability PersonaShow `shouldBe` Nothing
      requiredCapability Pins `shouldBe` Nothing
      requiredCapability (Btw "x") `shouldBe` Nothing
      requiredCapability MemoryList `shouldBe` Nothing
      requiredCapability (MemoryRm 1) `shouldBe` Nothing
      requiredCapability StickerStats `shouldBe` Nothing
      requiredCapability Version `shouldBe` Nothing

  describe "tierSatisfied" $ do
    it "orders member < group_admin < owner" $ do
      tierSatisfied TierMember TierMember `shouldBe` True
      tierSatisfied TierGroupAdmin TierMember `shouldBe` False
      tierSatisfied TierGroupAdmin TierGroupAdmin `shouldBe` True
      tierSatisfied TierOwner TierGroupAdmin `shouldBe` False
      tierSatisfied TierOwner TierOwner `shouldBe` True
      tierSatisfied TierMember TierOwner `shouldBe` True
