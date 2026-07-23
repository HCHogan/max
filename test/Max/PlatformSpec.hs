module Max.PlatformSpec (spec) where

import Max.Platform
import OneBot.Action (Action (..))
import OneBot.Types (GroupId (..), MessageId (..), UserId (..))
import Test.Hspec

spec :: Spec
spec = do
  describe "isForeignId" $ do
    it "claims the mapped range and its negation" $ do
      isForeignId (-1000000000001) `shouldBe` True
      isForeignId foreignIdBase `shouldBe` True
      isForeignId 1000000000001 `shouldBe` True

    it "leaves QQ ids and private pseudo groups alone" $ do
      isForeignId 1145141919 `shouldBe` False
      isForeignId (-1145141919) `shouldBe` False
      isForeignId 0 `shouldBe` False

  describe "routeAction" $ do
    let wechat =
          PlatformBackend
            { pbName = "wechatpad",
              pbOwnsId = isForeignId,
              pbSend = \_ -> pure (Right ()),
              pbCall = \_ _ -> pure (Left "stub")
            }
        dflt =
          PlatformBackend
            { pbName = "napcat",
              pbOwnsId = const False,
              pbSend = \_ -> pure (Right ()),
              pbCall = \_ _ -> pure (Left "stub")
            }
        route a = (routeAction [wechat] dflt a).pbName

    it "routes foreign group sends to the owning backend" $
      route (SendGroupMsg (GroupId (-1000000000005)) []) `shouldBe` "wechatpad"

    it "routes QQ ids to the default" $ do
      route (SendGroupMsg (GroupId 1145141919) []) `shouldBe` "napcat"
      route (SendPrivateMsg (UserId 2001) []) `shouldBe` "napcat"

    it "routes foreign message reactions by message id" $
      route (SetMsgEmojiLike (MessageId (-1000000000042)) 124 True) `shouldBe` "wechatpad"

    it "targetless actions fall to the default" $
      route (SetFriendAddRequest "flag" True) `shouldBe` "napcat"
