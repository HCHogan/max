-- | ffmpeg edge that fits media to a provider's vision envelope: images are
-- downscaled to a patch grid within their cap, videos are re-encoded as the
-- planned rendition (window, speed, frame rate, grid) and measured afterwards.
module Max.Media.Prepare
  ( prepareImageWithin,
    PreparedVideo (..),
    prepareVideoFile,
  )
where

import Control.Applicative ((<|>))
import Control.Exception (IOException, try)
import Data.Aeson (Value (..), eitherDecodeStrict', withObject, (.:), (.:?))
import Data.Aeson.Types (Parser, parseEither)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Maybe (catMaybes, fromMaybe, listToMaybe, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Max.ImagePrep (prepareImageForLLM)
import Max.Media.Vision
import Max.ModelCatalog (VisionLimits (..))
import Max.Util (withTempDirectory)
import Numeric (showFFloat)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Process (readProcessWithExitCode)
import System.Timeout (timeout)
import Text.Read (readMaybe)

-- | Without limits this is 'prepareImageForLLM'. With limits, an image above
-- 'imageTokenCap' is re-encoded at the largest patch grid within it; an image
-- that cannot be measured or shrunk keeps its bytes and counts as a whole item.
prepareImageWithin :: Maybe VisionLimits -> Text -> ByteString -> IO (Text, ByteString)
prepareImageWithin limits mime bytes0 = do
  (mime', bytes) <- prepareImageForLLM mime bytes0
  case limits of
    Nothing -> pure (mime', bytes)
    Just vision -> case imageDimensions bytes of
      Just (width, height) | imageVisionTokens width height <= imageTokenCap vision -> pure (mime', bytes)
      measured -> do
        shrunk <- try @IOException (shrink (imageTokenCap vision) measured bytes)
        pure $ case shrunk of
          Right (Just out) -> ("image/jpeg", out)
          _ -> (mime', bytes)
  where
    shrink cap measured bytes = withTempDirectory "max-vision-image-" $ \workspace -> do
      let input = workspace </> "input.bin"
          output = workspace </> "output.jpg"
      BS.writeFile input bytes
      size <- maybe (probeImage input) (pure . Just) measured
      case size of
        Nothing -> pure Nothing
        Just (width, height) -> do
          let (columns, rows) = imageGrid cap width height
          result <- run 30 "ffmpeg" ["-y", "-v", "error", "-i", input, "-vf", "scale=" <> show (columns * 32) <> ":" <> show (rows * 32), "-frames:v", "1", "-q:v", "3", output]
          case result of
            Right _ -> Just <$> BS.readFile output
            Left _ -> pure Nothing
    probeImage input = do
      result <- run 15 "ffprobe" ["-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height", "-of", "csv=p=0", input]
      pure $ case result of
        Right out | [w, h] <- T.splitOn "," (T.strip (T.pack out)) -> (,) <$> readMaybe (T.unpack w) <*> readMaybe (T.unpack h)
        _ -> Nothing

data PreparedVideo = PreparedVideo
  { videoBytes :: !ByteString,
    videoTokens :: !Int,
    videoPlan :: !VideoPlan,
    videoSourceSeconds :: !Double
  }

-- | Render one video file within an item budget. Rotation is applied, audio
-- dropped, and the output is measured so its token count is exact.
prepareVideoFile :: VisionLimits -> Int -> VideoWindow -> FilePath -> IO (Either Text PreparedVideo)
prepareVideoFile limits budget window path = do
  probed <- probeVideo path
  case probed of
    Left failure -> pure (Left failure)
    Right source -> withTempDirectory "max-vision-video-" $ \workspace -> do
      let plan = planVideo limits budget source window
          output = workspace </> "rendition.mp4"
          decimal value = showFFloat (Just 6) value ""
          filters =
            "setpts=(PTS-STARTPTS)/"
              <> decimal plan.planSpeed
              <> ",fps="
              <> decimal plan.planFps
              <> ",scale="
              <> show (plan.planColumns * 32)
              <> ":"
              <> show (plan.planRows * 32)
              <> ",setsar=1"
      encoded <-
        run 300 "ffmpeg" $
          ["-y", "-v", "error", "-ss", decimal plan.planStart, "-t", decimal plan.planSeconds, "-i", path]
            <> ["-an", "-sn", "-dn", "-vf", filters, "-c:v", "libx264", "-preset", "veryfast", "-crf", "26", "-pix_fmt", "yuv420p", "-movflags", "+faststart", output]
      case encoded of
        Left failure -> pure (Left ("视频转码失败：" <> failure))
        Right _ -> do
          measured <- run 60 "ffprobe" ["-v", "error", "-count_frames", "-select_streams", "v:0", "-show_entries", "stream=width,height,nb_read_frames", "-of", "csv=p=0", output]
          case measured of
            Right out
              | [w, h, n] <- mapMaybe (readMaybe . T.unpack) (T.splitOn "," (T.strip (T.pack out))),
                n > 0 -> do
                  let tokens = videoVisionTokens n (w `div` 32) (h `div` 32)
                  if tokens > videoTokenCap limits
                    then pure (Left "转码结果超出单个视频的视觉预算")
                    else do
                      bytes <- BS.readFile output
                      pure (Right (PreparedVideo bytes tokens plan source.sourceSeconds))
            _ -> pure (Left "转码结果无法测量")

-- Display size (after rotation) and duration of the first video stream.
probeVideo :: FilePath -> IO (Either Text VideoSource)
probeVideo path = do
  result <- run 30 "ffprobe" ["-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height:stream_side_data=rotation:stream_tags=rotate:format=duration", "-of", "json", path]
  pure $ case result of
    Left failure -> Left ("无法读取视频信息：" <> failure)
    Right out -> either (Left . ("无法读取视频信息：" <>) . T.pack) Right (eitherDecodeStrict' (BC.pack out) >>= parseEither source)
  where
    source :: Value -> Parser VideoSource
    source = withObject "ffprobe" $ \o -> do
      streams <- o .: "streams"
      format <- o .: "format"
      stream <- maybe (fail "no video stream") pure (listToMaybe streams)
      width <- stream .: "width"
      height <- stream .: "height"
      sideData <- fromMaybe [] <$> stream .:? "side_data_list"
      tags <- stream .:? "tags"
      tagged <- maybe (pure Nothing) (.:? "rotate") tags
      rotations <- traverse (.:? "rotation") sideData
      duration <- format .: "duration"
      let rotation = listToMaybe (catMaybes rotations) <|> (readMaybe . T.unpack =<< tagged)
          quarter = maybe False (\r -> (abs (r :: Int) `mod` 180) == 90) rotation
      seconds <- maybe (fail "unknown duration") pure (readMaybe (T.unpack duration))
      pure (if quarter then VideoSource height width seconds else VideoSource width height seconds)

run :: Int -> FilePath -> [String] -> IO (Either Text String)
run seconds program arguments = do
  result <- try @IOException (timeout (seconds * 1_000_000) (readProcessWithExitCode program arguments ""))
  pure $ case result of
    Left failure -> Left (T.pack (show failure))
    Right Nothing -> Left (T.pack program <> " timed out")
    Right (Just (ExitSuccess, out, _)) -> Right out
    Right (Just (ExitFailure code, _, err)) -> Left (T.pack program <> " exited " <> T.pack (show code) <> ": " <> T.take 300 (T.strip (T.pack err)))
