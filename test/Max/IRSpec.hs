module Max.IRSpec (spec) where

import Data.Aeson (Value, object, toJSON, (.=))
import Data.Aeson.Types (parseEither, parseJSON)
import Data.Either (isLeft)
import Data.Text (Text)
import Data.Text qualified as T
import Max.IR
import Max.Platform.Types (Platform (..), PrincipalIdentityId (..))
import Test.Hspec

spec :: Spec
spec = do
  vocabularySpec
  utilitySpec
  codecSpec

mkMeta :: MediaKind -> Maybe Text -> Maybe Text -> Maybe Int -> MediaMeta
mkMeta kind name description size =
  MediaMeta
    { kind,
      mime = Nothing,
      sizeBytes = fromIntegral <$> size,
      name,
      description,
      raw = Nothing
    }

mention :: Text -> Node 'Canonical
mention = NMention (MentionIdentity (PrincipalIdentityId 7))

vocabularySpec :: Spec
vocabularySpec = describe "fallbackText" $ do
  it "renders text verbatim" $
    fallbackText (NText "你好") `shouldBe` "你好"

  it "renders a mention as @display" $
    fallbackText (mention "张三") `shouldBe` "@张三"

  it "renders a named emote" $
    fallbackText (NEmote (Emote PlatformQQ "5" (Just "惊讶") Nothing))
      `shouldBe` "[表情: 惊讶]"

  it "renders an unnamed emote without a dangling separator" $
    fallbackText (NEmote (Emote PlatformQQ "5" Nothing Nothing))
      `shouldBe` "[表情]"

  it "treats a blank emote name as absent" $
    fallbackText (NEmote (Emote PlatformQQ "5" (Just "  ") Nothing))
      `shouldBe` "[表情]"

  it "renders an image with its caption" $
    fallbackText (NMedia Nothing (mkMeta MImage Nothing (Just "两只猫") Nothing))
      `shouldBe` "[图片: 两只猫]"

  it "never renders a blank caption (the 053 regression)" $
    fallbackText (NMedia Nothing (mkMeta MImage Nothing (Just "") Nothing))
      `shouldBe` "[图片]"

  it "renders a file with name and size" $
    fallbackText (NMedia Nothing (mkMeta MFile (Just "a.txt") Nothing (Just 1536)))
      `shouldBe` "[文件: a.txt (1.5KB)]"

  it "falls back to the filename when a video has no caption" $
    fallbackText (NMedia Nothing (mkMeta MVideo (Just "demo.mp4") Nothing Nothing))
      `shouldBe` "[视频: demo.mp4]"

  it "renders a sticker bare" $
    fallbackText (NMedia Nothing (mkMeta MSticker Nothing Nothing Nothing))
      `shouldBe` "[表情包]"

  it "renders a card with deduped parts" $
    fallbackText
      ( NCard
          Card
            { title = Just "哔哩哔哩",
              subtitle = Just "一个视频",
              url = Just "https://b23.tv/x",
              tag = Just "哔哩哔哩",
              preview = Nothing,
              raw = Nothing
            }
      )
      `shouldBe` "[分享: 哔哩哔哩 | 一个视频 | https://b23.tv/x]"

  it "renders an empty card without separators" $
    fallbackText (NCard (Card Nothing Nothing Nothing Nothing Nothing Nothing))
      `shouldBe` "[分享]"

  it "renders forward markers with and without counts" $ do
    fallbackText (NForward (ForwardRef "fid" (Just 12))) `shouldBe` "[聊天记录: 12条]"
    fallbackText (NForward (ForwardRef "fid" Nothing)) `shouldBe` "[聊天记录]"

  it "renders unsupported content by its description, falling back to source" $ do
    fallbackText (NUnsupported (Unsupported "qq:record" "语音消息" Nothing))
      `shouldBe` "[语音消息]"
    fallbackText (NUnsupported (Unsupported "qq:record" " " Nothing))
      `shouldBe` "[qq:record]"

  it "plainText concatenates without inventing separators" $
    plainText (Body [NText "看", mention "张三", NText " 发的图"])
      `shouldBe` "看@张三 发的图"

utilitySpec :: Spec
utilitySpec = do
  describe "humanBytes" $
    it "picks sensible units" $ do
      humanBytes 512 `shouldBe` "512B"
      humanBytes 1536 `shouldBe` "1.5KB"
      humanBytes (3 * 1024 * 1024) `shouldBe` "3.0MB"

  describe "truncateText" $ do
    it "leaves short text alone" $
      truncateText 5 "abc" `shouldBe` "abc"
    it "bounds long text with an ellipsis" $ do
      let out = truncateText 5 "abcdefgh"
      T.length out `shouldBe` 5
      out `shouldBe` "abcd…"

  describe "mergeText / trimEdges" $ do
    it "merges adjacent text runs and drops empties" $
      mergeText [NText "a", NText "", NText "b", mention "张三", NText "c"]
        `shouldBe` [NText "ab", mention "张三", NText "c"]
    it "trims whitespace seams at the edges only" $
      trimEdges ([NText "  hi ", NText "there  "] :: [Node 'Canonical])
        `shouldBe` [NText "hi ", NText "there"]
    it "drops a whitespace-only edge node entirely" $
      trimEdges [NText "  ", mention "张三"]
        `shouldBe` [mention "张三"]
    it "leaves non-text edges untouched" $
      trimEdges [mention "张三", NText " ok ", mention "李四"]
        `shouldBe` [mention "张三", NText " ok ", mention "李四"]

-- | Round-trip corpus: every node kind, optional fields both present and
-- absent, CJK payloads, raw platform values.
codecCorpus :: [(String, Body 'Canonical)]
codecCorpus =
  [ ("plain text", Body [NText "你好, world"]),
    ("mention identity", Body [mention "张三", NText " 在吗"]),
    ("mention all", Body [NMention MentionAll "全体成员"]),
    ( "emote with raw",
      Body [NEmote (Emote PlatformQQ "5" (Just "惊讶") (Just (object ["faceText" .= ("惊讶" :: Text)])))]
    ),
    ( "media blob",
      Body [NMedia (Just (MediaBlob "abc123")) (mkMeta MImage Nothing (Just "两只猫") (Just 182000))]
    ),
    ( "media remote sticker",
      Body [NMedia (Just (MediaRemote "https://x/s.png")) (mkMeta MSticker Nothing Nothing Nothing)]
    ),
    ("media sourceless", Body [NMedia Nothing (mkMeta MFile (Just "a.txt") Nothing Nothing)]),
    ( "card",
      Body
        [ NCard
            Card
              { title = Just "标题",
                subtitle = Nothing,
                url = Just "https://example.com",
                tag = Just "知乎",
                preview = Just (MediaRemote "https://x/p.jpg"),
                raw = Just (object ["app" .= ("com.tencent.structmsg" :: Text)])
              }
        ]
    ),
    ("forward", Body [NForward (ForwardRef "7391948582" (Just 3))]),
    ("unsupported", Body [NUnsupported (Unsupported "qq:record" "语音消息" Nothing)]),
    ( "mixed",
      Body
        [ NText "看这个 ",
          mention "张三",
          NText " ",
          NMedia (Just (MediaBlob "deadbeef")) (mkMeta MImage Nothing Nothing Nothing),
          NEmote (Emote PlatformWeChatPad "wx:doge" Nothing Nothing)
        ]
    )
  ]

decodeBody :: Value -> Either String (Body 'Canonical)
decodeBody = parseEither parseJSON

codecSpec :: Spec
codecSpec = describe "canonical codec" $ do
  it "round-trips every corpus body" $
    mapM_
      (\(label, body) -> (label, decodeBody (toJSON body)) `shouldBe` (label, Right body))
      codecCorpus

  it "encodes media refs as their stored string form" $ do
    renderMediaRef (MediaBlob "ab12") `shouldBe` "blob:ab12"
    parseMediaRef "blob:ab12" `shouldBe` MediaBlob "ab12"
    parseMediaRef "https://x/a.png" `shouldBe` MediaRemote "https://x/a.png"

  it "rejects a v1 flat array" $
    decodeBody (toJSON [object ["type" .= ("text" :: Text), "text" .= ("hi" :: Text)]])
      `shouldSatisfy` isLeft

  it "rejects an unknown version" $
    decodeBody (object ["v" .= (1 :: Int), "nodes" .= ([] :: [Value])])
      `shouldSatisfy` isLeft

  it "rejects an unknown node type" $
    decodeBody (object ["v" .= (2 :: Int), "nodes" .= [object ["type" .= ("hologram" :: Text)]]])
      `shouldSatisfy` isLeft

  it "rejects a mention with neither identity nor all" $
    decodeBody
      ( object
          [ "v" .= (2 :: Int),
            "nodes" .= [object ["type" .= ("mention" :: Text), "display" .= ("x" :: Text)]]
          ]
      )
      `shouldSatisfy` isLeft
