-- |
-- Downscale oversized images before they go to a vision model.
-- Providers downscale big images server-side anyway (and bill the
-- base64 of whatever we send, at 4/3 the raw size), so shipping a
-- multi-MB original is pure waste.  Anything over
-- 'compressThresholdBytes' gets re-encoded via ffmpeg to JPEG with
-- the long edge capped at 'maxLongEdge' — roughly the resolution
-- vision endpoints normalise to.
--
-- Best-effort by design: any ffmpeg failure (or a "compressed"
-- result that isn't actually smaller) falls back to the original
-- bytes, so callers never lose an image to this step.
module Max.ImagePrep
  ( prepareImageForLLM,
    compressThresholdBytes,
  )
where

import Control.Exception (IOException, try)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Text (Text)
import Max.Util (withTempDirectory)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Process (readProcessWithExitCode)
import System.Timeout (timeout)

-- | Images at or below this pass through untouched.
compressThresholdBytes :: Int
compressThresholdBytes = 1024 * 1024

-- | Long-edge pixel cap for the re-encode — around what vision
-- endpoints normalise to, so detail loss is what the model would
-- have suffered anyway.
maxLongEdge :: Int
maxLongEdge = 1568

-- | @(mime, bytes) -> (mime', bytes')@: JPEG re-encode when the
-- image is over threshold, identity otherwise.  Animated GIFs pass
-- through — flattening one to a JPEG frame would silently change
-- meaning; the callers that only need a frame extract one themselves.
prepareImageForLLM :: Text -> ByteString -> IO (Text, ByteString)
prepareImageForLLM mime bytes
  | BS.length bytes <= compressThresholdBytes = pure (mime, bytes)
  | mime == "image/gif" = pure (mime, bytes)
  | otherwise = do
      r <- try @IOException compress
      pure $ case r of
        Right (Just out) | BS.length out < BS.length bytes -> ("image/jpeg", out)
        _ -> (mime, bytes)
  where
    compress = withTempDirectory "max-imgprep-" $ \workspace -> do
      let inPath = workspace </> "input.bin"
          outPath = workspace </> "output.jpg"
      BS.writeFile inPath bytes
      let -- Fit within a maxLongEdge box, aspect preserved.  The
          -- min() terms stop small-but-heavy images from being
          -- upscaled; force_divisible_by keeps dimensions even for
          -- the encoder.
          edge = show maxLongEdge
          scale =
            "scale='min(iw," <> edge <> ")':'min(ih," <> edge <> ")'\
            \:force_original_aspect_ratio=decrease:force_divisible_by=2"
      res <-
        timeout 15_000_000 $
          readProcessWithExitCode
            "ffmpeg"
            ["-y", "-loglevel", "error", "-i", inPath, "-vf", scale, "-frames:v", "1", "-q:v", "4", outPath]
            ""
      out <- case res of
        Just (ExitSuccess, _, _) -> Just <$> BS.readFile outPath
        _ -> pure Nothing
      pure out
