module Max.PlatformSpec (spec) where

import Data.Aeson (decodeStrict', object, (.=))
import Data.Foldable (for_)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import Max.IR
import Max.IR.Lower (textOnlyCaps)
import Max.IR.Prompt (promptText)
import Max.Platform
import Max.Platform.QQ (qqIngestBody)
import Max.Platform.Types (NativeUserId (..))
import Max.WechatHook
  ( CallbackMsg (..),
    WechatHookConfig (..),
    callbackPathSegments,
    displayNameFor,
    parseCallback,
    wechatHookCapabilities,
    wechatHookInboundBody,
  )
import Max.Wechatpad (parseFrameIds, wechatInboundBody, wechatpadCapabilities)
import OneBot.Action (Action (..))
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
    it "advertises exactly its emit-only text contract" $
      wechatHookCapabilities `shouldBe` textOnlyCaps

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
          whSilenceSeconds = 21600
        }
