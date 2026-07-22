module Max.BilibiliSpec (spec) where

import Data.Aeson (Value, decodeStrict')
import Data.Maybe (fromJust)
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import Max.Bilibili
import Test.Hspec

json :: Text -> Value
json = fromJust . decodeStrict' . TE.encodeUtf8

spec :: Spec
spec = do
  describe "findBiliRef" $ do
    it "extracts a BV id from a full URL" $
      findBiliRef "看看这个 https://www.bilibili.com/video/BV1kFFCzGEuS/ 好活"
        `shouldBe` Just (RefBvid "BV1kFFCzGEuS")

    it "extracts a bare BV id" $
      findBiliRef "BV1kFFCzGEuS 这个" `shouldBe` Just (RefBvid "BV1kFFCzGEuS")

    it "extracts an av id from the URL path form" $
      findBiliRef "https://www.bilibili.com/video/av170001" `shouldBe` Just (RefAvid 170001)

    it "does not false-positive on prose containing av" $
      findBiliRef "这个 avatar 不错" `shouldBe` Nothing

    it "extracts a b23.tv short link" $
      findBiliRef "【视频】 https://b23.tv/ab12Cd3 分享" `shouldBe` Just (RefShort "https://b23.tv/ab12Cd3")

    it "prefers the BV id when both are present" $
      findBiliRef "https://b23.tv/xxx 即 BV1kFFCzGEuS" `shouldBe` Just (RefBvid "BV1kFFCzGEuS")

    it "skips a too-short BV prefix and finds a later real one" $
      findBiliRef "BV不是 但 BV1kFFCzGEuS 是" `shouldBe` Just (RefBvid "BV1kFFCzGEuS")

    it "returns Nothing for unrelated text" $
      findBiliRef "今天天气不错" `shouldBe` Nothing

  describe "parseVideoInfo" $ do
    it "parses the view API envelope" $ do
      let v =
            json
              "{\"code\":0,\"message\":\"0\",\"data\":{\"bvid\":\"BV1xx411c7mD\",\"aid\":170001,\
              \\"cid\":279786,\"title\":\"标题\",\"desc\":\"简介\",\"duration\":213,\
              \\"pubdate\":1500000000,\"videos\":2,\
              \\"owner\":{\"mid\":1,\"name\":\"UP主\"},\
              \\"stat\":{\"view\":100,\"danmaku\":5,\"reply\":7,\"favorite\":8,\"coin\":9,\"share\":3,\"like\":42}}}"
      case parseVideoInfo v of
        Left e -> expectationFailure (show e)
        Right info -> do
          info.bvBvid `shouldBe` "BV1xx411c7mD"
          info.bvAid `shouldBe` 170001
          info.bvCid `shouldBe` 279786
          info.bvTitle `shouldBe` "标题"
          info.bvUp `shouldBe` "UP主"
          info.bvDurationSec `shouldBe` 213
          info.bvParts `shouldBe` 2
          info.bvStat.bsLike `shouldBe` 42
          info.bvStat.bsCoin `shouldBe` 9

    it "surfaces an API refusal with its code" $
      case parseVideoInfo (json "{\"code\":-404,\"message\":\"啥都木有\"}") of
        Left e -> e `shouldSatisfy` (/= "")
        Right _ -> expectationFailure "expected Left"

  describe "parseComments" $ do
    it "parses replies with user, likes, text" $ do
      let v =
            json
              "{\"code\":0,\"data\":{\"replies\":[\
              \{\"member\":{\"uname\":\"甲\"},\"like\":10,\"content\":{\"message\":\"顶\"}},\
              \{\"member\":{\"uname\":\"乙\"},\"like\":3,\"content\":{\"message\":\"一般\"}}]}}"
      parseComments 15 v
        `shouldBe` Right [BiliComment "甲" 10 "顶", BiliComment "乙" 3 "一般"]

    it "treats a null/absent replies field as empty" $ do
      parseComments 15 (json "{\"code\":0,\"data\":{\"replies\":null}}") `shouldBe` Right []
      parseComments 15 (json "{\"code\":0,\"data\":{}}") `shouldBe` Right []

  describe "parseStreamUrl" $
    it "takes the first durl entry with its size" $ do
      let v =
            json
              "{\"code\":0,\"data\":{\"durl\":[{\"url\":\"https://cdn/x.mp4\",\"size\":123456}]}}"
      parseStreamUrl v `shouldBe` Right ("https://cdn/x.mp4", 123456)
