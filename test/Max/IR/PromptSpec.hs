module Max.IR.PromptSpec (spec) where

import Data.Foldable (for_)
import Data.Int (Int64)
import Data.Text (Text)
import Max.IR
import Max.IR.Prompt
import Max.Platform.Types (NativeUserId (..), Platform (..))
import Test.Hspec

roster :: MentionRoster
roster =
  MentionRoster
    { known = \nid -> nid `elem` [NativeUserId "123456", NativeUserId "987654321"],
      names = [("张三", NativeUserId "123456")]
    }

mentionNode :: Text -> Node 'ModelParsed
mentionNode digits = NMention (NativeUserId digits) digits

stickerMeta :: Maybe Text -> MediaMeta
stickerMeta description =
  MediaMeta
    { kind = MSticker,
      mime = Nothing,
      sizeBytes = Nothing,
      name = Nothing,
      description,
      raw = Nothing
    }

imageMeta :: MediaMeta
imageMeta = (stickerMeta Nothing) {kind = MImage}

parse :: Text -> (Maybe Int64, Body 'ModelParsed)
parse = parseModelChunk roster

spec :: Spec
spec = do
  mentionSpec
  tokenSpec
  roundTripSpec

mentionSpec :: Spec
mentionSpec = describe "mention parsing" $ do
  it "converts the canonical bracket token with the space convention" $
    parse "[@#123456] 你好"
      `shouldBe` (Nothing, Body [mentionNode "123456", NText " 你好"])

  it "converts a bare known span" $
    parse "@123456 在吗"
      `shouldBe` (Nothing, Body [mentionNode "123456", NText " 在吗"])

  it "keeps unknown ids as literal text" $
    parse "@111111 在吗"
      `shouldBe` (Nothing, Body [NText "@111111 在吗"])

  it "keeps out-of-range digit spans literal" $
    parse "@1234 hi" `shouldBe` (Nothing, Body [NText "@1234 hi"])

  it "does not convert inside an email-like span" $
    parse "a@123456.com" `shouldBe` (Nothing, Body [NText "a@123456.com"])

  it "rescues an @display-name span through the roster" $
    parse "@张三 你好"
      `shouldBe` (Nothing, Body [mentionNode "123456", NText " 你好"])

tokenSpec :: Spec
tokenSpec = describe "placeholder tokens" $ do
  it "extracts the reply target and strips the seam" $
    parse "[↩#98765] 说得对"
      `shouldBe` (Just 98765, Body [NText "说得对"])

  it "accepts negative reply ids (foreign compatibility namespace)" $
    fst (parse "[↩#-42] ok") `shouldBe` Just (-42)

  it "parses sticker ids, display forms and caption references" $ do
    parse "好的[sticker#42]"
      `shouldBe` (Nothing, Body [NText "好的", NMedia (RefSticker 42) (stickerMeta Nothing)])
    parse "[sticker#42: 柴犬瘫地]"
      `shouldBe` (Nothing, Body [NMedia (RefSticker 42) (stickerMeta Nothing)])
    parse "[sticker#柴犬瘫地]"
      `shouldBe` (Nothing, Body [NMedia (RefStickerDesc "柴犬瘫地") (stickerMeta (Just "柴犬瘫地"))])
    parse "[表情包#42]"
      `shouldBe` (Nothing, Body [NMedia (RefSticker 42) (stickerMeta Nothing)])

  it "parses image resends and swallows display attribute groups" $
    parse "[image#7407](29秒)"
      `shouldBe` (Nothing, Body [NMedia (RefImage 7407) imageMeta])

  it "parses faces, dropping the display name per the inbound form" $ do
    parse "[face#5]"
      `shouldBe` (Nothing, Body [NEmote (Emote PlatformQQ "5" Nothing Nothing)])
    parse "[face#5: 惊讶]"
      `shouldBe` (Nothing, Body [NEmote (Emote PlatformQQ "5" Nothing Nothing)])

  it "leaves non-token brackets literal" $
    parse "[not a token] hi"
      `shouldBe` (Nothing, Body [NText "[not a token] hi"])

roundTripSpec :: Spec
roundTripSpec = describe "round trip" $ do
  it "parse . emit ≡ id on parser output (the persisted-history contract)" $ do
    let inputs =
          [ "[@#123456] 你好",
            "@张三 你好",
            "喊 @987654321 来看[sticker#42]",
            "[↩#98765] 说得对 [face#5]",
            "[↩#-42] [image#7407] 再看一遍",
            "[sticker#柴犬瘫地]",
            "plain text, no tokens 中文",
            "a@123456.com stays [not a token]"
          ]
    for_ inputs $ \input -> do
      let parsed = parse input
          emitted = uncurry emitModelChunk parsed
      (input, parse emitted) `shouldBe` (input, parsed)

  it "emits the documented normal form" $
    emitModelChunk (Just 5) (Body [mentionNode "123456", NText " 好"])
      `shouldBe` "[↩#5] [@#123456] 好"
