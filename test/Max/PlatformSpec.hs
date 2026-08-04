module Max.PlatformSpec (spec) where

import Max.Platform
import Max.Platform.QQ (qqContentParts)
import Max.Platform.Store (renderCanonicalText)
import Max.Platform.Types (ContentPart (..), MediaSource (..))
import OneBot.Action (Action (..))
import OneBot.Segment (ImageSegInfo (..), Segment (..))
import OneBot.Types (GroupId (..), MessageId (..), UserId (..))
import Test.Hspec

spec :: Spec
spec = do
  describe "explicit platform backend registry" $ do
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

  describe "QQ canonical image normalization" $ do
    it "turns NapCat's blank summary into a durable image marker" $ do
      let image = SegImage (ImageSegInfo (Just "https://qq.example/image.jpg") (Just 0) (Just ""))
          expected =
            [ ContentMedia
                (RemoteMedia "https://qq.example/image.jpg" Nothing Nothing Nothing)
                (Just "[image]")
            ]
      qqContentParts image `shouldBe` expected
      renderCanonicalText expected `shouldBe` "[image]"
  where
    fake platform =
      PlatformBackend
        { pbPlatform = platform,
          pbName = platform,
          pbSend = const (pure (Right ())),
          pbCall = \_ _ -> pure (Left "unused")
        }
