module Max.IR.PromptSpec (spec) where

import Data.Foldable (for_)
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as T
import Max.IR
import Max.IR.Prompt
import Max.Platform.Types (CanonicalMessageId (..), EventKind (..), Platform (..), PrincipalId (..))
import Test.Hspec

-- | The roster the prompt showed this turn: display name → principal.  There
-- is no membership predicate any more (ADR 004) — an id that names nobody
-- fails to resolve to an account at send time and the mention folds back to
-- text, which is the same answer the old whitelist gave.
roster :: MentionRoster
roster = MentionRoster {names = [("张三", PrincipalId 123)]}

mentionNode :: Int64 -> Node 'ModelParsed
mentionNode principal =
  NMention (PrincipalId principal) (if principal == 123 then "张三" else tshow principal)
  where
    tshow = T.pack . show

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
  systemEventSpec

-- | A meta event has no content nodes, so this is the whole of what the
-- transcript can say about it.  Every line has to name its target with the
-- same @#id@ the model uses everywhere else, or it cannot be matched to the
-- message it is about.
systemEventSpec :: Spec
systemEventSpec = describe "system event projection" $ do
  it "names the message a recall took back" $
    systemEventText EventRedaction (Just 7405) Nothing True
      `shouldBe` "[撤回了 #7405]"

  it "resolves a QQ reaction key to the same face name the model sends by" $
    systemEventText EventReaction (Just 7405) (Just "212") True
      `shouldSatisfy` \line ->
        "[贴了表情 " `T.isPrefixOf` line && " #7405]" `T.isSuffixOf` line && not ("212" `T.isInfixOf` line)

  it "keeps an uncurated face id numeric rather than calling it something else" $
    systemEventText EventReaction (Just 7405) (Just "999999") True
      `shouldBe` "[贴了表情 999999 #7405]"

  it "distinguishes removing a reaction from adding one" $
    systemEventText EventReaction (Just 7405) (Just "999999") False
      `shouldBe` "[取消了表情 999999 #7405]"

  -- A target that no longer resolves is still worth a line: the room saw
  -- something get taken back even when the ledger cannot say which thing.
  it "still reports an event whose target is not in the ledger" $
    systemEventText EventRedaction Nothing Nothing True
      `shouldBe` "[撤回了一条消息]"

  it "leaves an ordinary message to its own body" $
    systemEventText EventMessage (Just 7405) Nothing True `shouldBe` ""

mentionSpec :: Spec
mentionSpec = describe "mention parsing" $ do
  it "converts the canonical bracket token with the space convention" $
    parse "[@#123] 你好"
      `shouldBe` (Nothing, Body [mentionNode 123, NText " 你好"])

  it "converts a principal it has never seen, and lets resolution decide" $
    -- A hallucinated id is not the parser's problem: it resolves to no
    -- account on this conversation and the send path folds it to @name.
    parse "[@#999] 在吗"
      `shouldBe` (Nothing, Body [NMention (PrincipalId 999) "999", NText " 在吗"])

  it "no longer reads a bare @<digits> span as a mention" $
    -- That was QQ's wire spelling of an at-segment.  Principal ids are not
    -- QQ numbers, so the span is ordinary prose now.
    parse "@123456 在吗" `shouldBe` (Nothing, Body [NText "@123456 在吗"])

  it "does not convert inside an email-like span" $
    parse "a@123456.com" `shouldBe` (Nothing, Body [NText "a@123456.com"])

  it "rescues an @display-name span through the roster" $
    parse "@张三 你好"
      `shouldBe` (Nothing, Body [mentionNode 123, NText " 你好"])

  it "captures the explicit display fallback in the historical token" $
    parse "[@#123: 老张] 你好"
      `shouldBe` (Nothing, Body [NMention (PrincipalId 123) "老张", NText " 你好"])

tokenSpec :: Spec
tokenSpec = describe "placeholder tokens" $ do
  it "extracts the reply target and strips the seam" $
    parse "[↩#98765] 说得对"
      `shouldBe` (Just 98765, Body [NText "说得对"])

  it "still accepts a negative id, so a pre-cutover echo cannot leak as text" $
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
      `shouldBe` (Nothing, Body [NMedia (RefImage (CanonicalMessageId 7407) Nothing) imageMeta])

  it "parses one picture of a multi-image message" $ do
    parse "[image#7407.2]"
      `shouldBe` (Nothing, Body [NMedia (RefImage (CanonicalMessageId 7407) (Just 2)) imageMeta])
    parse "[image#7407.0: 示波器截图]"
      `shouldBe` (Nothing, Body [NMedia (RefImage (CanonicalMessageId 7407) (Just 0)) imageMeta])

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
          [ "[@#123] 你好",
            "@张三 你好",
            "喊 [@#987] 来看[sticker#42]",
            "[↩#98765] 说得对 [face#5]",
            "[↩#-42] [image#7407] 再看一遍",
            "看这张 [image#7407.2] 就够了",
            "[sticker#柴犬瘫地]",
            "plain text, no tokens 中文",
            "a@123456.com stays [not a token]"
          ]
    for_ inputs $ \input -> do
      let parsed = parse input
          emitted = uncurry emitModelChunk parsed
      (input, parse emitted) `shouldBe` (input, parsed)

  it "emits the documented normal form" $
    emitModelChunk (Just 5) (Body [mentionNode 123, NText " 好"])
      `shouldBe` "[↩#5] [@#123] 好"
