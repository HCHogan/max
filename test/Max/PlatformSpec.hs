module Max.PlatformSpec (spec) where

import Data.Aeson (object, (.=))
import Data.Foldable (for_)
import Data.Text (Text)
import Max.IR
import Max.IR.Lower (textOnlyCaps)
import Max.IR.Prompt (promptText)
import Max.Platform
import Max.Platform.QQ (qqIngestBody)
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
