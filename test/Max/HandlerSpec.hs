{-# LANGUAGE OverloadedStrings #-}

module Max.HandlerSpec (spec) where

import Max.Handler (isSilentReply, stripBareMarkers, stripStickerText)
import Test.Hspec

spec :: Spec
spec = do
  describe "isSilentReply" $ do
    it "matches a lone [沉默] and the empty reply" $ do
      isSilentReply "[沉默]" `shouldBe` True
      isSilentReply "" `shouldBe` True

    it "does not mute a reply that merely contains the marker" $ do
      isSilentReply "[沉默] 算了还是说一句" `shouldBe` False
      isSilentReply "我为什么要回 [沉默]" `shouldBe` False

    it "does not mute ordinary replies" $
      isSilentReply "今天天气不错" `shouldBe` False

  describe "stripStickerText" $ do
    it "leaves text without a sticker span untouched" $
      stripStickerText "你好呀，今天天气不错" `shouldBe` "你好呀，今天天气不错"

    it "removes a hallucinated [表情包: …] span" $
      stripStickerText "哈哈 [表情包: 一只金毛犬捂着眼睛] 好吧"
        `shouldBe` "哈哈  好吧"

    it "removes multiple spans" $
      stripStickerText "[表情包: a]中间[表情包: b]"
        `shouldBe` "中间"

    it "drops an unterminated span through the end" $
      stripStickerText "前面 [表情包: 没有闭合"
        `shouldBe` "前面 "

    it "keeps unrelated bracketed markers" $
      stripStickerText "[image] 和 [动画表情]"
        `shouldBe` "[image] 和 [动画表情]"

    it "preserves the real [表情包#<id>] send token" $ do
      stripStickerText "哈哈 [表情包#42] 好" `shouldBe` "哈哈 [表情包#42] 好"
      -- the captioned inbound form is a token too (id then colon)
      stripStickerText "[表情包#42: 猫猫震惊]" `shouldBe` "[表情包#42: 猫猫震惊]"

    it "strips a caption span but keeps a token in the same text" $
      stripStickerText "[表情包: 幻觉] 和 [表情包#7]"
        `shouldBe` " 和 [表情包#7]"

  describe "stripBareMarkers" $ do
    it "removes a bare [image] marker the model echoed" $
      stripBareMarkers "看这个 [image] 图" `shouldBe` "看这个  图"

    it "removes echoed [动画表情] / [face] / [forward] display markers" $ do
      stripBareMarkers "笑死 [动画表情]" `shouldBe` "笑死 "
      stripBareMarkers "[face] 哈哈 [forward]" `shouldBe` " 哈哈 "
      stripBareMarkers "旧行的 [mface] 标记" `shouldBe` "旧行的  标记"

    it "keeps the [image#<id>] resend token intact" $
      stripBareMarkers "转发 [image#123] 一下" `shouldBe` "转发 [image#123] 一下"

    it "keeps the [face#<id>] send token intact" $
      stripBareMarkers "回个 [face#178]" `shouldBe` "回个 [face#178]"

    it "leaves unrelated text untouched" $
      stripBareMarkers "没有图片标记" `shouldBe` "没有图片标记"
