{-# LANGUAGE OverloadedStrings #-}

module Max.HandlerSpec (spec) where

import Max.Handler (isSilentReply, parseSilence, stripBareMarkers, stripStickerText)
import Test.Hspec

spec :: Spec
spec = do
  describe "parseSilence / isSilentReply" $ do
    it "matches a lone [silence] and the empty reply" $ do
      parseSilence "[silence]" `shouldBe` Just Nothing
      parseSilence "" `shouldBe` Just Nothing

    it "accepts the pre-rename [沉默] marker" $
      parseSilence "[沉默]" `shouldBe` Just Nothing

    it "extracts a known reason face" $ do
      parseSilence "[silence:吃瓜]" `shouldBe` Just (Just 271)
      parseSilence "[silence:擦汗]" `shouldBe` Just (Just 97)
      parseSilence "[silence：疑问]" `shouldBe` Just (Just 32) -- full-width colon

    it "is silence-without-face for an unknown reason name" $
      parseSilence "[silence:量子纠缠]" `shouldBe` Just Nothing

    it "does not mute a reply that merely contains the marker" $ do
      parseSilence "[silence] 算了还是说一句" `shouldBe` Nothing
      parseSilence "[silence:吃瓜] 再说一句" `shouldBe` Nothing
      isSilentReply "我为什么要回 [silence]" `shouldBe` False

    it "does not mute ordinary replies" $
      isSilentReply "今天天气不错" `shouldBe` False

  describe "stripStickerText" $ do
    it "leaves text without a sticker span untouched" $
      stripStickerText "你好呀，今天天气不错" `shouldBe` "你好呀，今天天气不错"

    it "removes a hallucinated [sticker: …] span" $
      stripStickerText "哈哈 [sticker: 一只金毛犬捂着眼睛] 好吧"
        `shouldBe` "哈哈  好吧"

    it "removes the pre-rename [表情包: …] span too" $
      stripStickerText "哈哈 [表情包: 一只金毛犬捂着眼睛] 好吧"
        `shouldBe` "哈哈  好吧"

    it "removes multiple spans" $
      stripStickerText "[sticker: a]中间[表情包: b]"
        `shouldBe` "中间"

    it "drops an unterminated span through the end" $
      stripStickerText "前面 [sticker: 没有闭合"
        `shouldBe` "前面 "

    it "keeps unrelated bracketed markers" $
      stripStickerText "[image] 和 [sticker] 和 [动画表情]"
        `shouldBe` "[image] 和 [sticker] 和 [动画表情]"

    it "keeps English prose that happens to start with the word" $
      stripStickerText "[stickers are fun]" `shouldBe` "[stickers are fun]"

    it "preserves the real [sticker#<id>] send token" $ do
      stripStickerText "哈哈 [sticker#42] 好" `shouldBe` "哈哈 [sticker#42] 好"
      -- the captioned inbound form is a token too (id then colon)
      stripStickerText "[sticker#42: 猫猫震惊]" `shouldBe` "[sticker#42: 猫猫震惊]"
      -- pre-rename token forms survive as well
      stripStickerText "[表情包#42: 猫猫震惊]" `shouldBe` "[表情包#42: 猫猫震惊]"

    it "strips a caption span but keeps a token in the same text" $
      stripStickerText "[sticker: 幻觉] 和 [sticker#7]"
        `shouldBe` " 和 [sticker#7]"

  describe "stripBareMarkers" $ do
    it "removes a bare [image] marker the model echoed" $
      stripBareMarkers "看这个 [image] 图" `shouldBe` "看这个  图"

    it "removes echoed [sticker] / [face] / [forward] display markers" $ do
      stripBareMarkers "笑死 [sticker]" `shouldBe` "笑死 "
      stripBareMarkers "[face] 哈哈 [forward]" `shouldBe` " 哈哈 "
      stripBareMarkers "旧行的 [mface] 和 [动画表情] 标记" `shouldBe` "旧行的  和  标记"

    it "keeps the [image#<id>] resend token intact" $
      stripBareMarkers "转发 [image#123] 一下" `shouldBe` "转发 [image#123] 一下"

    it "keeps the [sticker#<id>] and [face#<id>] send tokens intact" $ do
      stripBareMarkers "发个 [sticker#42]" `shouldBe` "发个 [sticker#42]"
      stripBareMarkers "回个 [face#178]" `shouldBe` "回个 [face#178]"

    it "leaves unrelated text untouched" $
      stripBareMarkers "没有图片标记" `shouldBe` "没有图片标记"
