module OneBot.SegmentSpec (spec) where

import Data.Aeson (decodeStrict', encode, object, (.=))
import Data.ByteString.Lazy qualified as BSL
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import OneBot.Segment (CardInfo (..), ImageSegInfo (..), Segment (..), VideoSegInfo (..), renderPlainText)
import OneBot.Types (UserId (..))
import Test.Hspec

-- | Decode a segment from a UTF-8 Text literal (a ByteString literal
-- would latin-1-truncate the CJK).
decodeSeg :: Text -> Maybe Segment
decodeSeg = decodeStrict' . TE.encodeUtf8

spec :: Spec
spec = do
  faceSpec
  imageSpec
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

-- | ADR 004 moved the model's mention grammar out of this module: the
-- outbound lexer it used to hold (bare @\<5-11 digits\>, the roster
-- whitelist, the display-name rescue) was QQ's wire spelling, and principal
-- ids are not QQ numbers.  What survives here is the inbound rendering of a
-- QQ at-segment, which the command parser still reads.
mentionSpec :: Spec
mentionSpec = describe "at-segment rendering" $
  it "renders an inbound mention as the [@#qq] token" $
    renderPlainText [SegAt (UserId 12345678)] `shouldBe` "[@#12345678] "


imageSpec :: Spec
imageSpec = describe "image segments" $ do
  let napcat =
        "{\"type\":\"image\",\"data\":{\"url\":\"https://qq.example/image.jpg\",\"file\":\"A.jpg\",\"summary\":\"\",\"sub_type\":0}}"
      expected = SegImage (ImageSegInfo (Just "https://qq.example/image.jpg") (Just 0) (Just ""))

  it "round-trips a real NapCat image through the durable file encoding" $ do
    decodeSeg napcat `shouldBe` Just expected
    (decodeStrict' (BSL.toStrict (encode expected)) :: Maybe Segment) `shouldBe` Just expected
