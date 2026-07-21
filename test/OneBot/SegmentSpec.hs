module OneBot.SegmentSpec (spec) where

import Data.Aeson (decodeStrict')
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import OneBot.Segment (Segment (..), renderPlainText, segmentMentions)
import OneBot.Types (UserId (..))
import Test.Hspec

-- | Decode a segment from a UTF-8 Text literal (a ByteString literal
-- would latin-1-truncate the CJK).
decodeSeg :: Text -> Maybe Segment
decodeSeg = decodeStrict' . TE.encodeUtf8

spec :: Spec
spec = do
  faceSpec
  mentionSpec

faceSpec :: Spec
faceSpec = describe "face segments" $ do
  it "parses NapCat's raw.faceText into the face name (leading slash dropped)" $
    decodeSeg "{\"type\":\"face\",\"data\":{\"id\":\"14\",\"raw\":{\"faceIndex\":14,\"faceText\":\"/惊讶\"}}}"
      `shouldBe` Just (SegFace 14 (Just "惊讶"))

  it "parses a face without raw as nameless" $
    decodeSeg "{\"type\":\"face\",\"data\":{\"id\":14}}"
      `shouldBe` Just (SegFace 14 Nothing)

  it "treats a blank faceText as absent" $
    decodeSeg "{\"type\":\"face\",\"data\":{\"id\":\"14\",\"raw\":{\"faceText\":\"/\"}}}"
      `shouldBe` Just (SegFace 14 Nothing)

  it "renders named and nameless faces" $ do
    renderPlainText [SegFace 14 (Just "惊讶")] `shouldBe` "[face#14: 惊讶]"
    renderPlainText [SegFace 14 Nothing] `shouldBe` "[face#14]"

mentionSpec :: Spec
mentionSpec = describe "segmentMentions" $ do
  let roster = Set.fromList [UserId 12345678, UserId 10001, UserId 99999999999]
      conv = segmentMentions (`Set.member` roster)

  it "normalises to exactly one space after a converted mention" $
    conv "叫一下@12345678 看看"
      `shouldBe` [SegText "叫一下", SegAt (UserId 12345678), SegText " 看看"]

  it "converts a mention at the start and end of text (no trailing space at the end)" $
    conv "@12345678 收到了吗@10001"
      `shouldBe` [ SegAt (UserId 12345678),
                   SegText " 收到了吗",
                   SegAt (UserId 10001)
                 ]

  it "converts adjacent mentions, each followed by a space" $
    conv "@12345678 @10001 开会了"
      `shouldBe` [SegAt (UserId 12345678), SegText " ", SegAt (UserId 10001), SegText " 开会了"]

  it "inserts a space even when CJK is flush against the mention" $
    conv "问@12345678你好"
      `shouldBe` [SegText "问", SegAt (UserId 12345678), SegText " 你好"]

  it "keeps an id outside the roster as plain text" $
    conv "@87654321 在吗" `shouldBe` [SegText "@87654321 在吗"]

  it "keeps digit runs shorter than a QQ号 as plain text" $
    conv "发到 hank@163.com" `shouldBe` [SegText "发到 hank@163.com"]

  it "keeps spans glued to ASCII word characters as plain text" $
    conv "id是x@12345678y" `shouldBe` [SegText "id是x@12345678y"]

  it "keeps a lone @ and text without mentions untouched" $ do
    conv "@ 大家好" `shouldBe` [SegText "@ 大家好"]
    conv "没有提及任何人" `shouldBe` [SegText "没有提及任何人"]

  it "handles the 11-digit upper bound" $
    conv "@99999999999 hi"
      `shouldBe` [SegAt (UserId 99999999999), SegText " hi"]

  it "normalises spacing around multiple mentions in one line" $
    conv "@12345678 明天@10001 记得带伞"
      `shouldBe` [ SegAt (UserId 12345678),
                   SegText " 明天",
                   SegAt (UserId 10001),
                   SegText " 记得带伞"
                 ]
