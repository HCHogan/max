-- | Provider renditions of videos, cached by source content and preparation
-- parameters so repeated views reuse identical bytes (and the server's media
-- cache) instead of re-encoding.
module Max.Media.Rendition
  ( videoRendition,
    rawVideoAttachment,
  )
where

import Control.Exception (IOException)
import Control.Monad (mfilter)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base64 qualified as B64
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Effectful
import Effectful.Exception (try)
import Effectful.Log (Log, logAttention, logInfo, object, (.=))
import Effectful.PostgreSQL (WithConnection)
import Max.DB.VideoRendition
import Max.Effects.Blob (Blob, blobRefFromSha256, blobRefSha256, putBlob, readBlob)
import Max.Media.Prepare (PreparedVideo (..), prepareVideoFile)
import Max.Media.Vision (VideoAttachment (..), VideoPlan (..), VideoWindow (..), videoNote, videoTokenCap)
import Max.Time (fmtDurationSec)
import Max.ModelCatalog (VisionLimits (..))
import Max.Util (withTempDirectory)
import Numeric (showFFloat)
import System.Environment (lookupEnv)
import System.FilePath ((</>))

-- | One item-sized rendition of a window of the source video. The loader runs
-- only on a cache miss.
videoRendition ::
  (Blob :> es, WithConnection :> es, Log :> es, IOE :> es) =>
  VisionLimits ->
  VideoWindow ->
  Text ->
  Eff es (Either Text ByteString) ->
  Eff es (Either Text VideoAttachment)
videoRendition limits window source loadSource = do
  cached <- fetchVideoRendition source params
  reused <- case cached of
    Just stored | Just ref <- blobRefFromSha256 stored.renditionSha256 -> do
      bytes <- try @IOException (readBlob ref)
      pure (either (const Nothing) (Just . (,stored)) bytes)
    _ -> pure Nothing
  case reused of
    Just (bytes, stored) -> pure (Right (rendition bytes stored))
    Nothing -> do
      loaded <- loadSource
      case loaded of
        Left failure -> pure (Left failure)
        Right sourceBytes -> do
          -- A VA-API render node the host exposed for decoding, if any.
          device <- liftIO (mfilter (not . null) <$> lookupEnv "MAX_VAAPI_DEVICE")
          prepared <- liftIO $ withTempDirectory "max-rendition-" $ \workspace -> do
            let path = workspace </> "source"
            BS.writeFile path sourceBytes
            prepareVideoFile device limits (videoTokenCap limits) window path
          case prepared of
            Left failure -> do
              logAttention "video rendition failed" (object ["source" .= source, "params" .= params, "error" .= failure])
              pure (Left failure)
            Right video -> do
              ref <- putBlob video.videoBytes
              let plan = video.videoPlan
                  stored = StoredRendition (blobRefSha256 ref) video.videoTokens video.videoSourceSeconds plan.planStart plan.planSeconds plan.planSpeed
              storeVideoRendition source params stored
              logInfo "video rendition prepared" (object ["source" .= source, "params" .= params, "bytes" .= BS.length video.videoBytes, "vision_tokens" .= video.videoTokens, "decoder" .= video.videoDecoder])
              pure (Right (rendition video.videoBytes stored))
  where
    decimal value = T.pack (showFFloat (Just 1) value "")
    params =
      T.unwords
        [ "v1",
          "item=" <> T.pack (show limits.itemTokens),
          "seconds=" <> T.pack (show limits.videoMaxSeconds),
          "frames=" <> T.pack (show limits.videoMaxFrames),
          "pixels=" <> T.pack (show limits.videoMaxPixels),
          "start=" <> decimal (max 0 window.windowStart),
          "end=" <> maybe "end" decimal window.windowEnd
        ]
    rendition bytes stored =
      VideoAttachment
        ("data:video/mp4;base64," <> TE.decodeUtf8 (B64.encode bytes))
        (Just stored.visionTokens)
        (videoNote stored.sourceSeconds stored.startSeconds stored.spanSeconds stored.speed)

-- | The source bytes as-is, for profiles without a declared envelope.
rawVideoAttachment :: Text -> Maybe Double -> ByteString -> VideoAttachment
rawVideoAttachment mime duration bytes =
  VideoAttachment
    ("data:" <> mime <> ";base64," <> TE.decodeUtf8 (B64.encode bytes))
    Nothing
    (maybe "" (\seconds -> "（时长 " <> fmtDurationSec seconds <> "）") duration)
