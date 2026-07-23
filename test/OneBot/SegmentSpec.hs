module OneBot.SegmentSpec (spec) where

import Data.Aeson (decodeStrict', encode, object, (.=))
import Data.ByteString.Lazy qualified as BSL
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import OneBot.Segment (CardInfo (..), Segment (..), VideoSegInfo (..), renderPlainText, rescueNameMentions, segmentMentions)
import OneBot.Types (UserId (..))
import Test.Hspec

-- | Decode a segment from a UTF-8 Text literal (a ByteString literal
-- would latin-1-truncate the CJK).
decodeSeg :: Text -> Maybe Segment
decodeSeg = decodeStrict' . TE.encodeUtf8

spec :: Spec
spec = do
  faceSpec
  videoSpec
  cardSpec
  mentionSpec

cardSpec :: Spec
cardSpec = describe "lightapp card segments" $ do
  let biliCard =
        "{\"app\":\"com.tencent.miniapp_01\",\"prompt\":\"[QQ小程序]哔哩哔哩\",\"meta\":{\"detail_1\":\
        \{\"title\":\"哔哩哔哩\",\"desc\":\"【测试】超好看的视频\",\
        \\"qqdocurl\":\"https://b23.tv/ab12Cd3\",\"preview\":\"pic.example/x.jpg\",\"tag\":\"哔哩哔哩\"}}}"
      newsCard =
        "{\"app\":\"com.tencent.structmsg\",\"meta\":{\"news\":\
        \{\"title\":\"一篇文章\",\"desc\":\"文章摘要\",\"jumpUrl\":\"https://example.com/a\",\"tag\":\"知乎\"}}}"
      -- Build the envelope with aeson itself — hand-rolled escaping of
      -- the inner JSON string would mangle the CJK.
      wrap raw =
        TE.decodeUtf8 . BSL.toStrict . encode $
          object ["type" .= ("json" :: Text), "data" .= object ["data" .= (raw :: Text)]]

  it "parses a bilibili mini-app share card" $
    case decodeSeg (wrap biliCard) of
      Just (SegCard ci) -> do
        ci.ciApp `shouldBe` "com.tencent.miniapp_01"
        ci.ciTag `shouldBe` Just "哔哩哔哩"
        ci.ciDesc `shouldBe` Just "【测试】超好看的视频"
        ci.ciUrl `shouldBe` Just "https://b23.tv/ab12Cd3"
        ci.ciPreview `shouldBe` Just "pic.example/x.jpg"
      other -> expectationFailure ("expected SegCard, got: " <> show other)

  it "parses a structmsg news card (jumpUrl form)" $
    case decodeSeg (wrap newsCard) of
      Just (SegCard ci) -> do
        ci.ciTitle `shouldBe` Just "一篇文章"
        ci.ciUrl `shouldBe` Just "https://example.com/a"
      other -> expectationFailure ("expected SegCard, got: " <> show other)

  it "renders as a compact [card: ...] line with tag/title dedup" $
    case decodeSeg (wrap biliCard) of
      Just seg ->
        renderPlainText [seg]
          `shouldBe` "[card: 哔哩哔哩 | 【测试】超好看的视频 | https://b23.tv/ab12Cd3]"
      other -> expectationFailure ("expected a segment, got: " <> show other)

  it "keeps unparseable json segments as SegOther" $
    case decodeSeg "{\"type\":\"json\",\"data\":{\"data\":\"not json at all\"}}" of
      Just (SegOther "json" _) -> pure ()
      other -> expectationFailure ("expected SegOther, got: " <> show other)

  it "round-trips the raw payload through ToJSON" $
    case decodeSeg (wrap biliCard) of
      Just seg@(SegCard ci) -> do
        ci.ciRaw `shouldBe` biliCard
        (decodeStrict' (BSL.toStrict (encode seg)) :: Maybe Segment) `shouldBe` Just seg
      other -> expectationFailure ("expected SegCard, got: " <> show other)

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

videoSpec :: Spec
videoSpec = describe "video segments" $ do
  it "parses a NapCat video segment (string file_size tolerated)" $
    decodeSeg "{\"type\":\"video\",\"data\":{\"file\":\"abc.mp4\",\"url\":\"https://x/v.mp4\",\"file_size\":\"12345\"}}"
      `shouldBe` Just (SegVideo (VideoSegInfo "abc.mp4" (Just "https://x/v.mp4") (Just 12345)))

  it "parses a video without url" $
    decodeSeg "{\"type\":\"video\",\"data\":{\"file\":\"abc.mp4\"}}"
      `shouldBe` Just (SegVideo (VideoSegInfo "abc.mp4" Nothing Nothing))

  it "renders as the bare [video] marker" $
    renderPlainText [SegVideo (VideoSegInfo "f" Nothing Nothing)] `shouldBe` "[video]"

mentionSpec :: Spec
mentionSpec = describe "segmentMentions" $ do
  let roster = Set.fromList [UserId 12345678, UserId 10001, UserId 99999999999]
      conv = segmentMentions (`Set.member` roster)

  it "normalises to exactly one space after a converted mention" $
    conv "叫一下@12345678 看看"
      `shouldBe` [SegText "叫一下", SegAt (UserId 12345678), SegText " 看看"]

  it "converts the canonical [@#qq] token" $
    conv "叫一下[@#12345678] 看看"
      `shouldBe` [SegText "叫一下", SegAt (UserId 12345678), SegText " 看看"]

  it "keeps an unknown [@#qq] literal" $
    conv "[@#55555]" `shouldBe` [SegText "[@#55555]"]

  it "renders an inbound mention as the [@#qq] token" $
    renderPlainText [SegAt (UserId 12345678)] `shouldBe` "[@#12345678] "

  it "rescues @displayname into the canonical token, longest name first" $ do
    let names = [("阿飞", UserId 10001), ("阿飞哥", UserId 12345678)]
    rescueNameMentions names "@阿飞哥 看看" `shouldBe` "[@#12345678] 看看"
    rescueNameMentions names "@阿飞 看看" `shouldBe` "[@#10001] 看看"
    rescueNameMentions names "@路人 看看" `shouldBe` "@路人 看看"
    rescueNameMentions names "邮箱 a@阿飞.com" `shouldBe` "邮箱 a[@#10001].com"

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
