module Max.Media.VisionSpec (spec) where

import Data.ByteString qualified as BS
import Data.ByteString.Base64 qualified as B64
import Data.Maybe (isJust)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Max.LLM.Types (ChatMessage (..), ContentBlock (..))
import Max.Media.Prepare (PreparedVideo (..), prepareImageWithin, prepareVideoFile)
import Max.Media.Vision
import Max.ModelCatalog (VisionLimits (..))
import System.Directory (findExecutable)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (callProcess)
import Test.Hspec

limits :: VisionLimits
limits = VisionLimits 49152 16384 600 768 25165824

spec :: Spec
spec = describe "vision envelope" $ do
  describe "image sizes" $ do
    it "reads PNG, GIF, JPEG and WebP headers" $ do
      imageDimensions (BS.pack ([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 13] <> map (fromIntegral . fromEnum) "IHDR" <> [0, 0, 7, 128, 0, 0, 4, 56])) `shouldBe` Just (1920, 1080)
      imageDimensions (BS.pack (map (fromIntegral . fromEnum) "GIF89a" <> [0x40, 0x01, 0xf0, 0x00])) `shouldBe` Just (320, 240)
      -- SOI, an APP0 segment to skip, then SOF0 with height 600 and width 800.
      imageDimensions (BS.pack [0xff, 0xd8, 0xff, 0xe0, 0, 4, 0, 0, 0xff, 0xc0, 0, 17, 8, 2, 88, 3, 32]) `shouldBe` Just (800, 600)
      imageDimensions (BS.pack (map (fromIntegral . fromEnum) "RIFF" <> [0, 0, 0, 0] <> map (fromIntegral . fromEnum) "WEBPVP8X" <> replicate 8 0 <> [0x1f, 0x03, 0, 0x57, 0x02, 0])) `shouldBe` Just (800, 600)
      imageDimensions "not an image" `shouldBe` Nothing

    it "counts tokens the way the server rounds and upscales" $ do
      imageVisionTokens 1024 1024 `shouldBe` 1024
      imageVisionTokens 1568 1176 `shouldBe` 49 * 37
      imageVisionTokens 20 2000 `shouldBe` 80
      imageVisionTokens 10 10 `shouldBe` 64

    it "prices inline images from their header and unknown media as a whole item" $ do
      let png = BS.pack ([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 13] <> map (fromIntegral . fromEnum) "IHDR" <> [0, 0, 4, 0, 0, 0, 4, 0])
          url = "data:image/png;base64," <> TE.decodeUtf8 (B64.encode png)
      blockVisionTokens limits (ImageDataUrl url) `shouldBe` 1024
      blockVisionTokens limits (ImageDataUrl "data:image/png;base64,AAAA") `shouldBe` 16384
      blockVisionTokens limits (VideoDataUrl "data:video/mp4;base64,AAAA" (Just 9000)) `shouldBe` 9000
      blockVisionTokens limits (VideoDataUrl "data:video/mp4;base64,AAAA" Nothing) `shouldBe` 12288

  describe "video plans" $ do
    it "keeps short clips at 2 fps within what the video processor keeps" $ do
      let plan = planVideo limits 16384 (VideoSource 1080 1920 16) wholeVideo
      videoTokenCap limits `shouldBe` 12288
      plan.planSpeed `shouldBe` 1
      plan.planFps `shouldBe` 2
      plan.planTokens `shouldSatisfy` (<= 12288)
      (plan.planColumns * plan.planRows) `shouldSatisfy` (>= 700)
      plan.planColumns `shouldSatisfy` (< plan.planRows)

    it "lowers the frame rate before frames become illegible" $ do
      let plan = planVideo limits 16384 (VideoSource 1920 1080 300) wholeVideo
      plan.planFps `shouldSatisfy` (< 1)
      (plan.planColumns * plan.planRows) `shouldSatisfy` (>= 240)
      plan.planTokens `shouldSatisfy` (<= 16384)

    it "compresses windows longer than the server accepts and windows the rest" $ do
      let overview = planVideo limits 16384 (VideoSource 1280 720 1000) wholeVideo
          detail = planVideo limits 16384 (VideoSource 1280 720 1000) (VideoWindow 100 (Just 160))
      overview.planSeconds / overview.planSpeed `shouldSatisfy` (< 600)
      overview.planSpeed `shouldSatisfy` (> 1.6)
      (detail.planStart, detail.planSeconds, detail.planSpeed) `shouldBe` (100, 60, 1)
      planFrames (planVideo (VisionLimits 49152 16384 600 10 25165824) 16384 (VideoSource 640 360 60) wholeVideo) `shouldSatisfy` (<= 10)

    it "labels duration, window and time compression" $ do
      videoNote 16 0 16 1 `shouldBe` "（时长 16 秒）"
      videoNote 1000 0 1000 1.7 `shouldSatisfy` T.isInfixOf "1.7 倍速概览"
      videoNote 1000 100 60 1 `shouldSatisfy` T.isInfixOf "画面时间加 1 分 40 秒 为原片时间"

  describe "request budget" $ do
    let video n = VideoDataUrl ("data:video/mp4;base64," <> n) (Just 16384)
        messages =
          [ MsgUserBlocks [TextBlock "prompt", video "first"],
            MsgUser "question",
            MsgUserBlocks [TextBlock "a", video "second", TextBlock "b", video "third"],
            MsgUserBlocks [TextBlock "c", video "fourth"]
          ]
    it "evicts the oldest media until the request fits" $ do
      let tight = limits {requestTokens = 36864}
          (fitted, evicted) = fitVisionBudget tight messages
      evicted `shouldBe` 1
      case fitted of
        MsgUserBlocks [TextBlock text] : _ -> text `shouldSatisfy` T.isPrefixOf "prompt\n[这个附件已移出上下文"
        _ -> expectationFailure "the oldest video was not replaced by a note"
      length [() | MsgUserBlocks blocks <- fitted, VideoDataUrl {} <- blocks] `shouldBe` 3
      snd (fitVisionBudget tight (drop 2 messages)) `shouldBe` 0

    it "can strip every medium for a retry" $ do
      let (stripped, removed) = evictMedia maxBound messages
      removed `shouldBe` 4
      [() | MsgUserBlocks blocks <- stripped, VideoDataUrl {} <- blocks] `shouldBe` []

  describe "ffmpeg renditions" $ do
    it "renders a long 1080p video into a measured item-sized rendition" $ do
      ffmpeg <- findExecutable "ffmpeg"
      case ffmpeg of
        Nothing -> pendingWith "ffmpeg is not installed"
        Just _ -> withSystemTempDirectory "vision-spec" $ \dir -> do
          let source = dir </> "source.mp4"
          callProcess "ffmpeg" ["-v", "error", "-f", "lavfi", "-i", "testsrc2=size=1920x1080:rate=30:duration=70", "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", source]
          -- A render node that cannot be opened falls back to software.
          prepared <- prepareVideoFile (Just (dir </> "no-render-node")) limits 16384 wholeVideo source
          case prepared of
            Left failure -> expectationFailure (T.unpack failure)
            Right video -> do
              video.videoDecoder `shouldBe` "software"
              video.videoTokens `shouldSatisfy` (<= 12288)
              video.videoTokens `shouldSatisfy` (> 8000)
              video.videoSourceSeconds `shouldSatisfy` (\seconds -> seconds > 69 && seconds < 71)
              BS.length video.videoBytes `shouldSatisfy` (> 0)

    it "plans a rotated phone video in its display orientation" $ do
      ffmpeg <- findExecutable "ffmpeg"
      case ffmpeg of
        Nothing -> pendingWith "ffmpeg is not installed"
        Just _ -> withSystemTempDirectory "vision-spec" $ \dir -> do
          let coded = dir </> "coded.mp4"
              rotated = dir </> "rotated.mp4"
          callProcess "ffmpeg" ["-v", "error", "-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=30:duration=4", "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", coded]
          callProcess "ffmpeg" ["-v", "error", "-display_rotation", "90", "-i", coded, "-c", "copy", rotated]
          prepared <- prepareVideoFile Nothing limits 16384 wholeVideo rotated
          case prepared of
            Left failure -> expectationFailure (T.unpack failure)
            Right video -> video.videoPlan.planRows `shouldSatisfy` (> video.videoPlan.planColumns)

    it "shrinks an oversized image to the per-image cap" $ do
      ffmpeg <- findExecutable "ffmpeg"
      case ffmpeg of
        Nothing -> pendingWith "ffmpeg is not installed"
        Just _ -> withSystemTempDirectory "vision-spec" $ \dir -> do
          let source = dir </> "large.png"
          callProcess "ffmpeg" ["-v", "error", "-f", "lavfi", "-i", "color=c=gray:size=1080x9000", "-frames:v", "1", source]
          bytes <- BS.readFile source
          (_, prepared) <- prepareImageWithin (Just limits) "image/png" bytes
          let size = imageDimensions prepared
          size `shouldSatisfy` isJust
          fmap (uncurry imageVisionTokens) size `shouldSatisfy` maybe False (<= imageTokenCap limits)
