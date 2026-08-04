{-# LANGUAGE OverloadedStrings #-}

module Max.HandlerSpec (spec) where

import Max.DB.Message (MessageKind (..))
import Max.Handler (IngestOutcome (..), ingestAllowsDownstream, isSilentReply, parseSilence, recordAs)
import Max.IR.Prompt (promptText)
import Max.Platform.QQ (qqIngestBody)
import Max.Platform.Types (CanonicalMessageId (..), Platform (PlatformQQ))
import Max.ReplySend (stripBareMarkers, stripStickerText)
import OneBot.Event (GroupMessage (..), Sender (..))
import OneBot.Segment (Segment (..))
import OneBot.Types (GroupId (..), MessageId (..), UserId (..))
import Test.Hspec

spec :: Spec
spec = do
  describe "durable ingest policy" $ do
    it "allows media/dispatch work only after the immutable ledger is durable" $ do
      ingestAllowsDownstream (IngestDurable (CanonicalMessageId 1)) `shouldBe` True
      ingestAllowsDownstream IngestDuplicate `shouldBe` False
      ingestAllowsDownstream (IngestFailed "postgres unavailable") `shouldBe` False

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
      parseSilence "[silence:NO]" `shouldBe` Just (Just 123) -- refused topic
      -- any curated face works, not just the old 8-name silence set
      parseSilence "[silence:比心]" `shouldBe` Just (Just 319)
      parseSilence "[silence:捂脸]" `shouldBe` Just (Just 264)

    it "is silence-without-face for an unknown reason name" $
      parseSilence "[silence:量子纠缠]" `shouldBe` Just Nothing

    it "does not mute a reply that merely contains the marker" $ do
      parseSilence "[silence] 算了还是说一句" `shouldBe` Nothing
      parseSilence "[silence:吃瓜] 再说一句" `shouldBe` Nothing
      isSilentReply "我为什么要回 [silence]" `shouldBe` False

    -- The format guide drills "回谁就引谁", so the model quotes the
    -- message it is declining; that must not turn the marker into a
    -- literal message (production: [↩#id] [silence] went out as text).
    it "sees through leading quote handles" $ do
      parseSilence "[↩#7413] [silence]" `shouldBe` Just Nothing
      parseSilence "[↩#7413][silence:吃瓜]" `shouldBe` Just (Just 271)
      parseSilence "[↩#-88][↩#7413] [silence]" `shouldBe` Just Nothing -- forward-child id
      parseSilence "[↩#7413] 这条不用回但我说两句" `shouldBe` Nothing
      parseSilence "[↩#7413]" `shouldBe` Just Nothing -- a bare quote says nothing at all
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

  -- Every message is recorded; `kind` decides whether the transcript
  -- shows it.  The answer is re-derived from the same parser 'classify'
  -- uses, so the two can't drift into disagreeing about what a command
  -- is.
  describe "recordAs" $ do
    let msg segs =
          GroupMessage
            { selfId = UserId 1000,
              groupId = GroupId 7777,
              userId = UserId 2001,
              messageId = MessageId 9000,
              message = segs,
              rawMessage = "",
              sender = Sender (UserId 2001) (Just "Alice") Nothing
            }
        rec' = recordAs . msg

    it "records ordinary chat as chat, unrewritten" $ do
      rec' [SegText "今天吃啥"] `shouldBe` (KindChat, Nothing)
      rec' [SegAt (UserId 1000), SegText " 帮我看下这个报错"]
        `shouldBe` (KindChat, Nothing)

    it "projects QQ mentions in the structural prompt form" $ do
      promptText PlatformQQ (qqIngestBody [SegAt (UserId 2291939848), SegText " 你好"])
        `shouldBe` "[@#2291939848]  你好"
      snd (rec' [SegAt (UserId 1000), SegText " !fb 改成 B 方案"])
        `shouldBe` Just "[@#1000] 改成 B 方案"

    it "records operating commands as command" $ do
      fst (rec' [SegText "!ps"]) `shouldBe` KindCommand
      fst (rec' [SegText "!model list"]) `shouldBe` KindCommand

    -- Malformed still counts as a command: it gets an error reply, not
    -- an answer, so in the transcript it would read as a question
    -- nobody answered.
    it "records a malformed command as command" $
      fst (rec' [SegText "!pin abc def ghi"]) `shouldBe` KindCommand

    it "records the shell escape as command" $
      fst (rec' [SegText "! ls -la"]) `shouldBe` KindCommand

    -- The carve-out: !btw and !feedback bodies are things somebody said
    -- to the bot, which it answers.  They belong in the transcript, in
    -- exactly the form the implicit supplement path would have stored.
    it "records !btw and !feedback as chat, verb stripped" $ do
      rec' [SegText "!btw 顺便问一下 X"]
        `shouldBe` (KindChat, Just "顺便问一下 X")
      rec' [SegText "!feedback 改成 B 方案"]
        `shouldBe` (KindChat, Just "改成 B 方案")
      rec' [SegText "!fb 改成 B 方案"]
        `shouldBe` (KindChat, Just "改成 B 方案")

    -- The @-mention survives: it is part of what was said, and the
    -- implicit path keeps it too.
    it "keeps the mention when stripping the verb" $
      rec' [SegAt (UserId 1000), SegText " !fb 改成 B 方案"]
        `shouldBe` (KindChat, Just "[@#1000] 改成 B 方案")

    -- An empty body isn't conversation, it's a mistyped command — it
    -- gets a usage hint back, not an answer.
    it "records a bodiless !btw as command" $ do
      fst (rec' [SegText "!btw"]) `shouldBe` KindCommand
      fst (rec' [SegText "!feedback   "]) `shouldBe` KindCommand

    -- A bang that isn't followed by an identifier is just punctuation.
    it "leaves bang-prefixed prose as chat" $ do
      rec' [SegText "!!!"] `shouldBe` (KindChat, Nothing)
      rec' [SegText "!这什么鬼"] `shouldBe` (KindChat, Nothing)
