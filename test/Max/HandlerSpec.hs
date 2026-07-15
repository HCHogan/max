{-# LANGUAGE OverloadedStrings #-}

module Max.HandlerSpec (spec) where

import Max.Handler (stripStickerText)
import Test.Hspec

spec :: Spec
spec = do
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
