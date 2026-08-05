-- |
-- The image caption is the third sender of model-authored text, and it
-- learned the placeholder vocabulary last: production posted
-- @"[↩#493645310] 画好了，macOS belike：…"@ with the token as visible
-- text, weeks after the reply and narration paths both stopped doing
-- that.  These pin it to what the other two already do.
module Max.Tools.FilesSpec (spec) where

import Data.Text (Text)
import Max.IR
import Max.Platform.Types (CanonicalMessageId (..), noAdvertisedCaps, qqAdvertisedCaps)
import Max.Tools.Files (captionBody)
import OneBot.Types (GroupId (..))
import Test.Hspec

gid :: GroupId
gid = GroupId 7777

qqCaption :: Maybe Text -> (Maybe CanonicalMessageId, Body 'Canonical)
qqCaption = captionBody qqAdvertisedCaps gid

spec :: Spec
spec = describe "captionBody" $ do
  it "sends nothing when there is no caption" $
    qqCaption Nothing `shouldBe` (Nothing, Body [])

  it "sends nothing for a blank one" $
    qqCaption (Just "  \n ") `shouldBe` (Nothing, Body [])

  -- The newline is what keeps the caption off the image it rides with.
  it "keeps a plain caption, separated from the image" $
    qqCaption (Just "画好了")
      `shouldBe` (Nothing, Body [NText "画好了", NText "\n"])

  -- The regression.
  it "consumes a leading reply token instead of printing it" $
    qqCaption (Just "[↩#493645310] 画好了，macOS belike")
      `shouldBe` (Just (CanonicalMessageId 493645310), Body [NText "画好了，macOS belike", NText "\n"])

  -- Unlike a narration line, the message this rides on goes out either
  -- way, so a caption that is only a quote still quotes.
  it "still quotes when that is all the caption was" $
    qqCaption (Just "[↩#999]") `shouldBe` (Just (CanonicalMessageId 999), Body [])

  -- One message cannot be two, so the marker is eaten rather than shown.
  it "eats a [split] it cannot honour" $
    qqCaption (Just "画好了\n\n[split]")
      `shouldBe` (Nothing, Body [NText "画好了", NText "\n"])

  it "folds what would have been separate messages into the one it has" $
    qqCaption (Just "画好了 [split] 你看看")
      `shouldBe` (Nothing, Body [NText "画好了\n你看看", NText "\n"])

  -- A tool has no roster to resolve a principal against, so a mention in a
  -- caption folds to text — the same rendering an unresolvable mention gets
  -- everywhere else.
  it "renders a mention as text" $
    qqCaption (Just "[@#2001] 给你")
      `shouldBe` (Nothing, Body [NText "@2001 给你", NText "\n"])

  -- Dropped, not printed — same trade the narration path makes.
  it "drops a sticker placeholder rather than leaking it" $
    qqCaption (Just "看 [sticker#42]")
      `shouldBe` (Nothing, Body [NText "看", NText "\n"])

  it "drops unsupported reply, face, and QQ mention actions" $
    captionBody noAdvertisedCaps gid (Just "[↩#-1000000000790] [face#66] [@#2001: 小明] 收到")
      `shouldBe` (Nothing, Body [NText "@小明 收到", NText "\n"])
