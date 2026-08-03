module Max.PlatformSpec (spec) where

import Max.Platform
import OneBot.Action (Action (..))
import OneBot.Types (GroupId (..), MessageId (..), UserId (..))
import Test.Hspec

spec :: Spec
spec = describe "explicit platform backend registry" $ do
  it "selects only an exact declared platform" $ do
    (.pbPlatform) <$> backendForPlatform "matrix" [fake "qq", fake "matrix"]
      `shouldBe` Just "matrix"
    (.pbPlatform) <$> backendForPlatform "imessage" [fake "qq", fake "matrix"]
      `shouldBe` Nothing

  it "classifies authority without interpreting numeric ranges" $ do
    actionAddress (SendGroupMsg (GroupId (-1000000000001)) [])
      `shouldBe` ConversationAddress (-1000000000001)
    actionAddress (SendPrivateMsg (UserId 7) []) `shouldBe` DirectAddress 7
    actionAddress (SetMsgEmojiLike (MessageId 9) 1 True) `shouldBe` MessageAddress 9
    actionAddress (SetFriendAddRequest "flag" True) `shouldBe` AccountAddress
  where
    fake platform =
      PlatformBackend
        { pbPlatform = platform,
          pbName = platform,
          pbSend = const (pure (Right ())),
          pbCall = \_ _ -> pure (Left "unused")
        }
