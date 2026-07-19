module OneBot.SegmentSpec (spec) where

import Data.Set qualified as Set
import OneBot.Segment (Segment (..), segmentMentions)
import OneBot.Types (UserId (..))
import Test.Hspec

spec :: Spec
spec = describe "segmentMentions" $ do
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
