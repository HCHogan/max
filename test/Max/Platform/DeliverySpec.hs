module Max.Platform.DeliverySpec (spec) where

import Control.Exception (SomeException, try)
import Data.Aeson (toJSON)
import Data.Either (isLeft)
import Data.Maybe (fromJust, isNothing)
import Data.Text qualified as T
import Data.Time (UTCTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Effectful (runEff)
import Max.Effects.Blob (blobRefSha256, putBlob, runBlob)
import Max.IR
import Max.IR.Lower
import Max.Platform.Delivery
import Max.Platform.QQ (qqCapabilities)
import Max.Platform.Store (DeliveryCompletion (..))
import Max.Platform.Types (NativeEventId (..), NativeUserId (..), Platform (..), ReactionAction (..))
import Max.Util (withTempDirectory)
import OneBot.Action (Action (..))
import OneBot.Segment (CardInfo (..), Segment (..))
import OneBot.Types (MessageId (..), UserId (..))
import Test.Hspec

spec :: Spec
spec = do
  describe "canonical delivery media resolution" $ do
    it "resolves only native-tier media within the endpoint budget" $
      withTempDirectory "max-delivery-media-test" $ \root -> do
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
        media <- runEff . runBlob root $ loadDeliveryMedia caps body
        media.resolved `shouldBe` [(first, ResolvedUrl "https://x/a.png")]
        media.notes `shouldBe` []

    it "loads content-addressed sources and verifies their declared size" $
      withTempDirectory "max-delivery-media-test" $ \root -> do
        media <- runEff . runBlob root $ do
          blobRef <- putBlob "blob-payload"
          let source = fromJust (mediaBlobRef (blobRefSha256 blobRef))
              caps = textOnlyCaps {file = TierNative}
              body = Body [NMedia (Just source) fileMeta]
          loadDeliveryMedia caps body
        fmap snd media.resolved `shouldBe` [ResolvedBytes "blob-payload"]

    -- ADR 003 §2: a blob the store cannot produce bytes for is sourceless,
    -- not oversized.  Poisoning the delivery would take the message's text
    -- down with the picture.
    it "leaves an unreadable blob unresolved so lowering folds it to text" $
      withTempDirectory "max-delivery-media-test" $ \root -> do
        let missing = fromJust (mediaBlobRef (T.replicate 64 "a"))
            caps = textOnlyCaps {image = TierNative}
            body = Body [NText "看这个", NMedia (Just missing) imageMeta]
        media <- runEff . runBlob root $ loadDeliveryMedia caps body
        media.resolved `shouldBe` []
        map (.subject) media.notes `shouldBe` ["media_source"]
        map (.outcome) media.notes `shouldBe` [NoteFolded]

        let lowered =
              lower
                LowerEnv
                  { platform = PlatformQQ,
                    caps,
                    attribution = Nothing,
                    mentionNative = const Nothing,
                    mediaResolve = (`lookup` media.resolved),
                    replyTarget = Nothing
                  }
                body
        lowered.chunks `shouldBe` [[NText "看这个[图片: 两只猫]"]]

    it "still refuses media whose stored bytes contradict the canonical size" $
      withTempDirectory "max-delivery-media-test" $ \root -> do
        outcome <- try @SomeException . runEff . runBlob root $ do
          blobRef <- putBlob "not-twelve-bytes"
          let source = fromJust (mediaBlobRef (blobRefSha256 blobRef))
              caps = textOnlyCaps {file = TierNative}
          media <- loadDeliveryMedia caps (Body [NMedia (Just source) fileMeta])
          pure (length media.resolved)
        outcome `shouldSatisfy` isLeft

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

  -- ADR 003 §7's one unimplemented promise: a deterministic rejection is
  -- retryable-shaped forever, and every retry re-blocks the endpoint's
  -- ordered lane behind one dead row.
  describe "delivery attempt budget" $ do
    it "keeps retrying a rejection while the budget lasts" $
      case toCompletion 1 epoch (AttemptRejected "retcode 1200") of
        DeliveryRetry err next -> do
          err `shouldBe` "retcode 1200"
          next `shouldSatisfy` (> epoch)
        other -> expectationFailure ("unexpected completion: " <> show other)

    -- Production delivery 72552 spent 159 attempts across an eleven-hour QQ
    -- edge outage and then landed.  An unreachable edge denies the ordered
    -- lane to nobody, so it is never budgeted.
    it "never budgets an unreachable edge" $
      case toCompletion (deliveryAttemptBudget * 10) epoch (AttemptRetryable "no client connected") of
        DeliveryRetry err next -> do
          err `shouldBe` "no client connected"
          next `shouldSatisfy` (> epoch)
        other -> expectationFailure ("unexpected completion: " <> show other)

    it "suppresses an over-budget rejection so the ordered lane releases" $
      case toCompletion deliveryAttemptBudget epoch (AttemptRejected "retcode 1200") of
        DeliverySuppressedAs reason -> do
          reason `shouldSatisfy` T.isInfixOf "retry budget exhausted"
          reason `shouldSatisfy` T.isInfixOf "retcode 1200"
        other -> expectationFailure ("unexpected completion: " <> show other)

    it "never turns an undecidable outcome into a content decision" $
      toCompletion (deliveryAttemptBudget * 2) epoch (AttemptOutcomeUnknown "transport timeout")
        `shouldBe` DeliveryUnknown "transport timeout" epoch

  describe "OneBot action emitter contract" $ do
    it "keeps every image of a multi-image QQ resend on the native tier" $
      withTempDirectory "max-delivery-media-test" $ \root -> do
        let first = fromJust (mediaRemoteRef "https://x/a.png")
            second = fromJust (mediaRemoteRef "https://x/b.png")
            body = Body [NMedia (Just first) imageMeta, NMedia (Just second) imageMeta]
        media <- runEff . runBlob root $ loadDeliveryMedia qqCapabilities body
        map fst media.resolved `shouldBe` [first, second]

        let lowered =
              lower
                LowerEnv
                  { platform = PlatformQQ,
                    caps = qqCapabilities,
                    attribution = Nothing,
                    mentionNative = const Nothing,
                    mediaResolve = (`lookup` media.resolved),
                    replyTarget = Nothing
                  }
                body
        lowered.notes `shouldBe` []
        case lowered.chunks of
          [[NMedia (ResolvedUrl a) _, NMedia (ResolvedUrl b) _]] -> do
            a `shouldBe` "https://x/a.png"
            b `shouldBe` "https://x/b.png"
          other -> expectationFailure ("unexpected QQ lowering: " <> show other)
        traverse oneBotNodes lowered.chunks
          `shouldSatisfy` either (const False) (all ((== 2) . length))


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

epoch :: UTCTime
epoch = posixSecondsToUTCTime 0

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
