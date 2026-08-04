module Max.Platform.DeliverySpec (spec) where

import Control.Exception (bracket)
import Data.Aeson (toJSON)
import Data.Maybe (fromJust, isNothing)
import Effectful (runEff)
import Max.Effects.Blob (blobRefSha256, putBlob, runBlob)
import Max.IR
import Max.IR.Lower
import Max.Platform.Delivery
import Max.Platform.QQ (qqCapabilities)
import Max.Platform.Types (NativeEventId (..), NativeUserId (..), Platform (..), ReactionAction (..))
import OneBot.Action (Action (..))
import OneBot.Segment (CardInfo (..), Segment (..))
import OneBot.Types (MessageId (..), UserId (..))
import System.Directory (createDirectory, getTemporaryDirectory, removeFile, removePathForcibly)
import System.IO (hClose, openBinaryTempFile)
import Test.Hspec

spec :: Spec
spec = do
  describe "canonical delivery media resolution" $ do
    it "resolves only native-tier media within the endpoint budget" $
      withBlobRoot $ \root -> do
        let first = fromJust (mediaRemoteRef "https://x/a.png")
            second = fromJust (mediaRemoteRef "https://x/b.png")
            caps = textOnlyCaps {image = TierNative, maxNativeMedia = 1}
            body =
              Body
                [ NText "看这个",
                  NMedia (Just first) imageMeta,
                  NMedia Nothing imageMeta,
                  NMedia (Just second) imageMeta
                ]
        resolved <- runEff . runBlob root $ loadDeliveryMedia caps body
        resolved `shouldBe` [(first, ResolvedUrl "https://x/a.png")]

    it "loads content-addressed sources and verifies their declared size" $
      withBlobRoot $ \root -> do
        resolved <- runEff . runBlob root $ do
          blobRef <- putBlob "blob-payload"
          let source = fromJust (mediaBlobRef (blobRefSha256 blobRef))
              caps = textOnlyCaps {file = TierNative}
              body = Body [NMedia (Just source) fileMeta]
          loadDeliveryMedia caps body
        fmap snd resolved `shouldBe` [ResolvedBytes "blob-payload"]

    it "re-lowers failed native media to text without reviving declared drops" $ do
      let caps =
            textOnlyCaps
              { image = TierNative,
                video = TierDrop,
                file = TierNative,
                maxNativeMedia = 3
              }
          fallback = mediaTextCaps caps
      fallback.image `shouldBe` TierText
      fallback.video `shouldBe` TierDrop
      fallback.file `shouldBe` TierText
      fallback.maxNativeMedia `shouldBe` 0

  describe "OneBot action emitter contract" $ do
    it "emits every structural node advertised by QQ capabilities" $ do
      let cardRaw =
            "{\"app\":\"fixture\",\"meta\":{\"news\":{\"tag\":\"tag\",\"title\":\"title\",\"jumpUrl\":\"https://example.test\"}}}"
          nativeCard =
            SegCard
              CardInfo
                { ciApp = "fixture",
                  ciTag = Just "tag",
                  ciTitle = Just "title",
                  ciDesc = Nothing,
                  ciUrl = Just "https://example.test",
                  ciPreview = Nothing,
                  ciRaw = cardRaw
                }
          card = Card (Just "title") Nothing (Just "https://example.test") (Just "tag") Nothing (Just (toJSON nativeCard))
          nodes =
            [ NText "hello",
              NMention (NativeUserId "123") "Alice",
              NEmote (Emote PlatformQQ "66" (Just "惊讶") Nothing),
              NMedia (ResolvedUrl "https://example.test/image.png") imageMeta,
              NMedia (ResolvedUrl "https://example.test/sticker.png") imageMeta {kind = MSticker},
              NCard card
            ]
      case oneBotNodes nodes of
        Right [SegText "hello", SegAt (UserId 123), SegFace 66 (Just "惊讶"), SegImage {}, SegImage {}, cardSegment] ->
          cardSegment `shouldBe` nativeCard
        other -> expectationFailure ("unexpected QQ emitter output: " <> show other)

      qqCapabilities.mention `shouldBe` TierNative
      qqCapabilities.reply `shouldBe` TierNative
      qqCapabilities.emote `shouldBe` TierNative
      qqCapabilities.image `shouldBe` TierNative
      qqCapabilities.sticker `shouldBe` TierNative
      qqCapabilities.card `shouldBe` TierNative
      qqCapabilities.reaction `shouldBe` True
      qqCapabilities.edit `shouldBe` False
      qqCapabilities.redact `shouldBe` False

      oneBotReplySegment 0 (Just (NativeEventId "42"))
        `shouldBe` Right [SegReply (MessageId 42)]
      oneBotReplySegment 1 (Just (NativeEventId "42")) `shouldBe` Right []

    it "maps an advertised QQ reaction to the native add/remove action" $ do
      case oneBotReactionAction (NativeEventId "42") "212" ReactionAdd of
        Just (SetMsgEmojiLike target emoji added) -> do
          target `shouldBe` MessageId 42
          emoji `shouldBe` 212
          added `shouldBe` True
        other -> expectationFailure ("unexpected reaction action: " <> show other)
      oneBotReactionAction (NativeEventId "$matrix") "👍" ReactionAdd `shouldSatisfy` isNothing

imageMeta :: MediaMeta
imageMeta =
  MediaMeta
    { kind = MImage,
      mime = Just "image/png",
      sizeBytes = Nothing,
      name = Just "a.png",
      description = Just "两只猫",
      raw = Nothing
    }

fileMeta :: MediaMeta
fileMeta =
  MediaMeta
    { kind = MFile,
      mime = Just "application/octet-stream",
      sizeBytes = Just 12,
      name = Just "a.bin",
      description = Nothing,
      raw = Nothing
    }

withBlobRoot :: (FilePath -> IO a) -> IO a
withBlobRoot = bracket acquire removePathForcibly
  where
    acquire = do
      tmp <- getTemporaryDirectory
      (path, handle) <- openBinaryTempFile tmp "max-delivery-media-test"
      hClose handle
      removeFile path
      createDirectory path
      pure path
