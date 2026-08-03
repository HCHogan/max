-- |
-- The image caption is the third sender of model-authored text, and it
-- learned the placeholder vocabulary last: production posted
-- @"[↩#493645310] 画好了，macOS belike：…"@ with the token as visible
-- text, weeks after the reply and narration paths both stopped doing
-- that.  These pin it to what the other two already do.
module Max.Tools.FilesSpec (spec) where

import Data.Text (Text)
import Max.Platform.Types (noConversationOutputCapabilities, qqConversationOutputCapabilities)
import Max.Tools.Files (captionSegs)
import OneBot.Segment (Segment (..))
import OneBot.Types (GroupId (..), MessageId (..), UserId (..))
import Test.Hspec

gid :: GroupId
gid = GroupId 7777

qqCaption :: Maybe Text -> [Segment]
qqCaption = captionSegs qqConversationOutputCapabilities gid

spec :: Spec
spec = describe "captionSegs" $ do
  it "sends nothing when there is no caption" $
    qqCaption Nothing `shouldBe` []

  it "sends nothing for a blank one" $
    qqCaption (Just "  \n ") `shouldBe` []

  -- The newline is what keeps the caption off the image it rides with.
  it "keeps a plain caption, separated from the image" $
    qqCaption (Just "画好了")
      `shouldBe` [SegText "画好了", SegText "\n"]

  -- The regression.
  it "consumes a leading reply token instead of printing it" $
    qqCaption (Just "[↩#493645310] 画好了，macOS belike")
      `shouldBe` [ SegReply (MessageId 493645310),
                   SegText "画好了，macOS belike",
                   SegText "\n"
                 ]

  -- Unlike a narration line, the message this rides on goes out either
  -- way, so a caption that is only a quote still quotes.
  it "still quotes when that is all the caption was" $
    qqCaption (Just "[↩#999]") `shouldBe` [SegReply (MessageId 999)]

  -- One message cannot be two, so the marker is eaten rather than shown.
  it "eats a [split] it cannot honour" $
    qqCaption (Just "画好了\n\n[split]")
      `shouldBe` [SegText "画好了", SegText "\n"]

  it "folds what would have been separate messages into the one it has" $
    qqCaption (Just "画好了 [split] 你看看")
      `shouldBe` [SegText "画好了\n你看看", SegText "\n"]

  it "converts a mention" $
    qqCaption (Just "[@#2001] 给你")
      `shouldBe` [SegAt (UserId 2001), SegText " 给你", SegText "\n"]

  -- Dropped, not printed — same trade the narration path makes.
  it "drops a sticker placeholder rather than leaking it" $
    qqCaption (Just "看 [sticker#42]")
      `shouldBe` [SegText "看", SegText "\n"]

  it "drops unsupported reply, face, and QQ mention actions" $
    captionSegs noConversationOutputCapabilities gid (Just "[↩#-1000000000790] [face#66] [@#2001: 小明] 收到")
      `shouldBe` [SegText "小明 收到", SegText "\n"]
