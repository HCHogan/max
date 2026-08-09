module Max.PlatformSpec (spec) where

import Data.Aeson (Value (Null), decodeStrict', object, (.=))
import Data.Foldable (for_)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime (..), fromGregorian)
import Max.IR
import Max.IR.Lower (OutboundCaps (..), Tier (TierNative), textOnlyCaps)
import Max.IR.Prompt (promptText)
import Max.Platform
import Max.Platform.Envelope (InboundEnvelope (..), IngestClass (LiveDelivery))
import Max.Platform.QQ (qqEnvelope, qqIngestBody)
import Max.Platform.Store (RegisteredEndpoint (..))
import Max.Platform.Types
  ( ConversationId (..),
    EndpointId (..),
    MessageRelation (..),
    NativeEventId (..),
    NativeUserId (..),
    PlatformAccountId (..),
  )
import Max.WechatHook
  ( CallbackMsg (..),
    Quote (..),
    WechatHookConfig (..),
    callbackPathSegments,
    displayNameFor,
    parseCallback,
    parseQuote,
    parseImagePayload,
    ImagePayload (..),
    wechatHookCapabilities,
    wechatHookContent,
    wechatHookInboundBody,
  )
import Max.Wechatpad (parseFrameIds, wechatInboundBody, wechatpadCapabilities)
import OneBot.Action (Action (..))
import OneBot.Event (GroupMessage (..), Sender (..))
import OneBot.Segment
  ( FileSegInfo (..),
    ImageSegInfo (..),
    Segment (..),
    VideoSegInfo (..),
    parseCard,
    renderPlainText,
  )
import OneBot.Types (GroupId (..), MessageId (..), UserId (..))
import Test.Hspec

spec :: Spec
spec = do
  describe "wechatpad frame ids" $ do
    it "advertises exactly its emit-only text contract" $
      wechatpadCapabilities `shouldBe` textOnlyCaps

    it "accepts numeric and wrapped ids without silently erasing them" $ do
      parseFrameIds
        ( object
            [ "from_user_name" .= object ["str" .= ("room@chatroom" :: Text)],
              "content" .= object ["str" .= ("wxid:\nhello" :: Text)],
              "msg_id" .= (12345 :: Int),
              "new_msg_id" .= object ["str" .= ("67890" :: Text)]
            ]
        )
        `shouldBe` Just ("12345", 67890)

    it "keeps non-text room events in canonical ingest instead of dropping them" $ do
      wechatInboundBody "wxid_max" "Max" 3 "<img encrypted payload>"
        `shouldBe` Body
          [ NUnsupported
              Unsupported
                { source = "wechatpad:3",
                  description = "微信图片消息",
                  raw =
                    Just
                      ( object
                          [ "msg_type" .= (3 :: Int),
                            "content_preview" .= ("<img encrypted payload>" :: Text)
                          ]
                      )
                }
          ]

  describe "wechathook callback" $ do
    -- Images are possible only through the bridge, because the hook reads them
    -- off the Windows host's own disk.  Advertising the capability without one
    -- would promise a send that always fails, where folding to text at least
    -- says something true.
    it "advertises images only when the bridge that carries them exists" $ do
      wechatHookCapabilities hookConfig {whBridgeUrl = ""} `shouldBe` textOnlyCaps
      -- And with a bridge, images are the only thing that changes: the send
      -- API takes a target and a string, so there is still no mention, quote
      -- or reaction to offer.
      wechatHookCapabilities hookConfig `shouldBe` textOnlyCaps {image = TierNative}

    -- The frame shape a hooked WeChat 4.1.10.27 client really sends (captured
    -- 2026-08-07; every identifier here is synthetic).  Parsing it from UTF-8
    -- bytes rather than from a rebuilt Value is the point: the field spelling,
    -- the encoding, and a msgid far past the range Double represents exactly
    -- are all contract, and a silent reshape upstream should fail here rather
    -- than in production.
    it "parses a chatroom callback from the wire bytes" $
      (decodeStrict' capturedCallback >>= parseCallback)
        `shouldBe` Just
          CallbackMsg
            { cbEventType = 1001,
              cbMsgId = 4611686018427387903,
              cbType = 1,
              cbTimestamp = 1750000000,
              cbWxid = "12345678901@chatroom",
              cbSender = "wxid_exampleuser02",
              cbRoomId = "12345678901@chatroom",
              cbContent = "好吧"
            }

    -- A chatroom frame repeats the room in @wxid@; a direct one puts the peer
    -- there and leaves @roomid@ empty.  So @roomid@ is the only field that
    -- discriminates, and reading @wxid@ for that would silently classify
    -- every direct message as a group.
    it "leaves roomid as the only group discriminator" $ do
      let direct =
            parseCallback $
              object
                [ "msgid" .= (7 :: Int),
                  "wxid" .= ("wxid_peer" :: Text),
                  "sender" .= ("wxid_peer" :: Text),
                  "roomid" .= ("" :: Text),
                  "content" .= ("hi" :: Text)
                ]
      (cbRoomId <$> direct) `shouldBe` Just ""
      (cbWxid <$> direct) `shouldBe` Just "wxid_peer"

    -- WeChat separates an @-token from the following text with U+2005, not a
    -- space.  Missing that leaves the separator in the text tier.
    it "resolves a mention through WeChat's U+2005 separator" $
      wechatHookInboundBody "wxid_max" "Max" 1 "@Max\x2005在吗"
        `shouldBe` Body [NMention (NativeUserId "wxid_max") "Max", NText "在吗"]

    it "keeps non-text room events in canonical ingest instead of dropping them" $
      wechatHookInboundBody "wxid_max" "Max" 49 "<appmsg>x</appmsg>"
        `shouldBe` Body
          [ NUnsupported
              Unsupported
                { source = "wechathook:49",
                  description = "微信分享或文件消息",
                  raw =
                    Just
                      ( object
                          [ "msg_type" .= (49 :: Int),
                            "content_preview" .= ("<appmsg>x</appmsg>" :: Text)
                          ]
                      )
                }
          ]

    -- The hook's contact database is unreachable on WeChat 4.x, so a name
    -- exists only if the operator wrote it down.  A blank entry is a typo,
    -- not a name, and must not become one.
    it "names only senders the operator actually listed" $ do
      displayNameFor hookConfig "wxid_exampleuser02" `shouldBe` Just "小李"
      displayNameFor hookConfig "wxid_unlisted" `shouldBe` Nothing
      displayNameFor hookConfig "wxid_blank" `shouldBe` Nothing

    it "decomposes the callback path the way wai's pathInfo will" $
      callbackPathSegments "/wechat/s3cret/callback" `shouldBe` ["wechat", "s3cret", "callback"]

  -- Quoting is the most conversational thing anyone does in a group, and it
  -- arrives under the same type-49 catch-all as files and links.  Before this
  -- was read, the reply text was lost outright and max saw only
  -- "[微信分享或文件消息]".
  describe "wechathook quote replies" $ do
    it "recovers the reply text and the quoted message's native id" $
      parseQuote quoteXml
        `shouldBe` Just Quote {qText = "走远了", qTargetId = "1234567890123456789"}

    it "emits the reply relation alongside the recovered text" $
      wechatHookContent "wxid_max" "Max" 49 quoteXml
        `shouldBe` ( Body [NText "走远了"],
                     [ReplyTo (NativeEventId "1234567890123456789")]
                   )

    -- <type> occurs on both sides of <refermsg> and means different things:
    -- 57 outside marks the quote, the inner one describes what was quoted.
    -- Reading the inner one would classify a quoted text message as not a
    -- quote at all.
    it "reads the outer subtype, not the quoted message's own type" $
      (qTargetId <$> parseQuote quoteXml) `shouldBe` Just "1234567890123456789"

    -- Files and links share type 49.  Anything without a quote payload must
    -- land on the unsupported path it took before, never vanish.
    it "leaves a non-quote app message on the unsupported path" $ do
      parseQuote "<msg><appmsg><type>6</type><title>报告.pdf</title></appmsg></msg>"
        `shouldBe` Nothing
      case wechatHookContent "wxid_max" "Max" 49 "<msg><appmsg><type>6</type></appmsg></msg>" of
        (Body [NUnsupported u], []) -> u.source `shouldBe` "wechathook:49"
        other -> expectationFailure ("expected unsupported degradation: " <> show other)

    it "decodes entities in the recovered text without unescaping twice" $
      qText
        <$> parseQuote
          "<msg><appmsg><type>57</type><title>a &amp;lt; b &amp; c</title>\
          \<refermsg><svrid>1</svrid></refermsg></appmsg></msg>"
        `shouldBe` Just "a &lt; b & c"

  -- An image callback names a picture it does not carry; these four numbers
  -- are how the bridge is told which stored file to go and decrypt.
  describe "wechathook image payloads" $ do
    it "reads the identifiers an image callback publishes" $
      parseImagePayload imageXml
        `shouldBe` Just
          ImagePayload
            { ipMd5 = "64fde48d714b83e236d7426c5ee710c1",
              ipOriginMd5 = "ea01957566b982eeb1280b55b2452f6e",
              ipLength = 172564,
              ipHdLength = 2351220
            }

    -- The attribute scan must respect boundaries: "length" also occurs inside
    -- "cdnthumblength", and reading the thumbnail's size as the image's would
    -- send the bridge hunting a file that does not exist.
    it "does not read cdnthumblength as length" $
      (ipLength <$> parseImagePayload imageXml) `shouldBe` Just 172564

    it "declines a payload that identifies nothing" $
      parseImagePayload "<msg><img aeskey=\"deadbeef\" /></msg>" `shouldBe` Nothing

  describe "explicit platform backend registry" $ do
    it "selects only an exact declared platform" $ do
      (.pbPlatform) <$> backendForPlatform "matrix" [fake "qq", fake "matrix"]
        `shouldBe` Just "matrix"
      (.pbPlatform) <$> backendForPlatform "imessage" [fake "qq", fake "matrix"]
        `shouldBe` Nothing

    it "classifies authority without interpreting numeric ranges" $ do
      actionAddress (SendGroupMsg (GroupId (-1000000000001)) [])
        `shouldBe` ConversationAddress (-1000000000001)
      actionAddress (SendPrivateMsg (UserId 7) []) `shouldBe` DirectAddress 7
      actionAddress (SetMsgEmojiLike (MessageId 9) 1 True) `shouldBe` MessageAddress 9
      actionAddress (SetFriendAddRequest "flag" True) `shouldBe` AccountAddress

  -- NapCat sends @"card": ""@ for every member who never set a 群名片, so the
  -- card is present-but-empty far more often than it is a name.  Preferring it
  -- with a plain @<|>@ stored that blank, and a blank name reads back as the
  -- bare principal id — the roster line the model gets was showing half the
  -- group as numbers.
  describe "QQ sender naming" $ do
    it "reads through an unset 群名片 to the nickname" $
      (qqEnvelope endpointFixture epoch Null (groupMessage (Sender (UserId 2701137803) (Just "坎特洛特月亮公主") (Just "")))).senderDisplayName
        `shouldBe` Just "坎特洛特月亮公主"

    it "still prefers a card that is actually set" $
      (qqEnvelope endpointFixture epoch Null (groupMessage (Sender (UserId 2701137803) (Just "坎特洛特月亮公主") (Just "月亮")))).senderDisplayName
        `shouldBe` Just "月亮"

    it "leaves a nameless sender nameless rather than blank" $
      (qqEnvelope endpointFixture epoch Null (groupMessage (Sender (UserId 2701137803) (Just "   ") (Just "")))).senderDisplayName
        `shouldBe` Nothing

  describe "QQ canonical image normalization" $ do
    it "turns NapCat's blank summary into a durable image marker" $ do
      let image = SegImage (ImageSegInfo (Just "https://qq.example/image.jpg") (Just 0) (Just ""))
          body = qqIngestBody [image]
      case body.nodes of
        [NMedia (Just ref) meta] -> do
          mediaRefRemoteUrl ref `shouldBe` Just "https://qq.example/image.jpg"
          meta.kind `shouldBe` MImage
          -- A blank summary is never stored as a caption (the 053 class).
          meta.description `shouldBe` Nothing
        other -> expectationFailure ("unexpected nodes: " <> show other)
      promptText body `shouldBe` "[image]"

  -- The prompt projection of the ingest body must reproduce the segment
  -- renderer token for token for everything that is *content*: persisted
  -- history and the model's learned round-trip contract pin this vocabulary
  -- (ADR 003 §4).
  --
  -- Mentions are deliberately excluded.  ADR 004 made the model's mention
  -- vocabulary name people, and 'renderPlainText' is QQ's own wire spelling
  -- of an at-segment; the two agreeing was the coincidence this project has
  -- been unpicking, not a contract.
  describe "QQ prompt-projection parity" $
    it "matches renderPlainText over the segment corpus" $ do
      let biliCard =
            parseCard
              "{\"app\":\"com.tencent.miniapp_01\",\"meta\":{\"detail_1\":\
              \{\"title\":\"哔哩哔哩\",\"desc\":\"一个视频\",\
              \\"qqdocurl\":\"https://b23.tv/x\",\"tag\":\"哔哩哔哩\"}}}"
          corpus :: [(String, [Segment])]
          corpus =
            [ ("reply stripped", [SegReply (MessageId 42), SegText "说得对"]),
              ("photo", [SegText "看", SegImage (ImageSegInfo (Just "https://x/a.jpg") (Just 0) Nothing)]),
              ("sticker", [SegImage (ImageSegInfo (Just "https://x/s.jpg") (Just 1) (Just "[动画表情]"))]),
              ("sourceless image", [SegImage (ImageSegInfo Nothing Nothing Nothing)]),
              ("named face", [SegFace 5 (Just "惊讶"), SegText "!"]),
              ("bare face", [SegFace 277 Nothing]),
              ("file", [SegFile (FileSegInfo "fid" "报告.pdf" (Just 1024) Nothing)]),
              ("video", [SegVideo (VideoSegInfo "vf" (Just "https://x/v.mp4") (Just 9000))]),
              ("card", [SegCard card | Just card <- [biliCard]]),
              ("record", [SegOther "record" (object ["file" .= ("x" :: Text)])]),
              ("forward", [SegOther "forward" (object ["id" .= ("7391948582" :: Text)])])
            ]
      for_ corpus $ \(label, segments) ->
        (label, promptText (qqIngestBody segments))
          `shouldBe` (label, renderPlainText segments)
  where
    endpointFixture = RegisteredEndpoint (EndpointId 1) (PlatformAccountId 1) (ConversationId 1) 1032949653

    epoch = UTCTime (fromGregorian 2026 8 7) 0

    groupMessage sender =
      GroupMessage
        { selfId = UserId 2107570581,
          groupId = GroupId 1032949653,
          userId = sender.userId,
          messageId = MessageId 7,
          message = [SegText "在吗"],
          rawMessage = "在吗",
          sender
        }

    fake platform =
      PlatformBackend
        { pbPlatform = platform,
          pbName = platform,
          pbSend = const (pure (Right ())),
          pbCall = \_ _ -> pure (Left "unused")
        }

    -- Encoded rather than written as a ByteString literal: IsString for
    -- ByteString truncates to 8 bits, which would quietly corrupt 好吧 and
    -- turn this fixture into a test of the wrong thing.
    capturedCallback =
      TE.encodeUtf8
        "{\"event_type\":1001,\"msgid\":4611686018427387903,\"type\":1,\
        \\"timestamp\":1750000000,\"wxid\":\"12345678901@chatroom\",\
        \\"sender\":\"wxid_exampleuser02\",\"roomid\":\"12345678901@chatroom\",\
        \\"content\":\"好吧\"}"

    -- The real shape a WeChat 4.1.10.27 quote-reply arrives in, identifiers
    -- replaced.  Kept whole rather than minimised: <type> appearing on both
    -- sides of <refermsg>, and <msgsource> carrying a second escaped document
    -- inside <refermsg>, are exactly the traps a hand-written reader falls
    -- into.
    quoteXml =
      "<?xml version=\"1.0\"?>\n\
      \<msg>\n\
      \\t<appmsg appid=\"\" sdkver=\"0\">\n\
      \\t\t<title>走远了</title>\n\
      \\t\t<type>57</type>\n\
      \\t\t<appattach><cdnthumbaeskey /><aeskey></aeskey></appattach>\n\
      \\t\t<refermsg>\n\
      \\t\t\t<type>1</type>\n\
      \\t\t\t<svrid>1234567890123456789</svrid>\n\
      \\t\t\t<fromusr>12345678901@chatroom</fromusr>\n\
      \\t\t\t<chatusr>wxid_exampleuser02</chatusr>\n\
      \\t\t\t<displayname>Max</displayname>\n\
      \\t\t\t<content>先给你个小甜点</content>\n\
      \\t\t\t<msgsource>&lt;msgsource&gt;&lt;membercount&gt;9&lt;/membercount&gt;&lt;/msgsource&gt;</msgsource>\n\
      \\t\t\t<createtime>1750000000</createtime>\n\
      \\t\t</refermsg>\n\
      \\t</appmsg>\n\
      \\t<fromusername>wxid_exampleuser01</fromusername>\n\
      \</msg>"

    -- The attribute order and neighbours WeChat really emits, so the
    -- cdnthumblength trap is present rather than described.
    imageXml =
      "<?xml version=\"1.0\"?>\n<msg>\n\t<img aeskey=\"62b1d1537315051cabcca2349d47499d\" \
      \encryver=\"1\" cdnthumbaeskey=\"62b1d1537315051cabcca2349d47499d\" \
      \cdnthumburl=\"305f0201\" cdnthumblength=\"17444\" cdnthumbheight=\"157\" \
      \cdnthumbwidth=\"210\" cdnmidimgurl=\"305f0201\" length=\"172564\" \
      \cdnbigimgurl=\"305f0201\" hdlength=\"2351220\" \
      \md5=\"64fde48d714b83e236d7426c5ee710c1\" \
      \originsourcemd5=\"ea01957566b982eeb1280b55b2452f6e\" />\n</msg>"

    hookConfig =
      WechatHookConfig
        { whApiUrl = "http://b650.example:30001",
          whListenHost = "127.0.0.1",
          whListenPort = 8787,
          whCallbackPath = "/wechat/s3cret/callback",
          whCallbackUrl = "http://max.example:8787/wechat/s3cret/callback",
          whSelfWxid = "wxid_max",
          whBotName = "Max",
          whChatrooms = ["12345678901@chatroom"],
          whNicknames =
            Map.fromList
              [ ("wxid_exampleuser02", "小李"),
                ("wxid_blank", "   ")
              ],
          whSilenceSeconds = 21600,
          whBridgeUrl = "http://b650.example:8788",
          whBridgeToken = "bridge-token"
        }
