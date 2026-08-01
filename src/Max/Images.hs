module Max.Images
  ( ImageJob (..),
    MediaKind (..),
    enqueueImages,
    enqueueImagesFromNode,
    downloadableImageCount,
    downloadableVideoCount,
    imageWorker,
  )
where

import Control.Exception (IOException, try)
import Data.Aeson
  ( FromJSON (..),
    ToJSON (..),
    Value (Object, String),
    withObject,
    withText,
    (.:),
    (.:?),
  )
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString qualified as BS
import Data.Foldable (for_, traverse_)
import Data.Int (Int64)
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Effectful
import Effectful.Concurrent.Async (Concurrent, forConcurrently_)
import Effectful.Log
import Effectful.PostgreSQL (WithConnection, execute)
import Max.DB.FetchQueue (JobKind (JobImage), enqueueJob)
import Max.DB.Stickers (StickerMeta, recordSticker, stickerMeta)
import Max.Effects.Blob (Blob, blobRefSha256, blobRefStoredPath, putBlob)
import Max.Effects.Http (Http, getBytes)
import Max.FetchQueue (FetchSignal, notifyFetch, runFetchLoop)
import Max.Util (withTempDirectory)
import OneBot.Event (GroupMessage (..))
import OneBot.Segment (ImageSegInfo (..), Segment (..), VideoSegInfo (..))
import OneBot.Types (GroupId (..), MessageId (..))
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Process (readProcessWithExitCode)

-- | What a queued download is.  Videos ride the same worker pool but
-- land in their own tables ('videos' / 'message_videos') with a
-- bigger size cap.
data MediaKind = MediaImage | MediaVideo
  deriving stock (Show, Eq)

-- | One image / mface / video waiting to be fetched and recorded.
-- 'sticker' carries the sticker metadata when the segment was a
-- 动画表情/商城表情, so the worker can register it in the sticker
-- library once the bytes (and thus the sha) are known.
data ImageJob = ImageJob
  { messageId :: !Int64,
    segIndex :: !Int,
    url :: !Text,
    groupId :: !(Maybe Int64),
    sticker :: !(Maybe StickerMeta),
    kind :: !MediaKind
  }
  deriving stock (Show)

-- The JSON below is a persisted format, not a wire detail: rows can
-- outlive a deploy, so fields are named (never positional) and
-- decoding stays tolerant of ones we no longer write.

instance ToJSON MediaKind where
  toJSON MediaImage = String "image"
  toJSON MediaVideo = String "video"

instance FromJSON MediaKind where
  parseJSON = withText "MediaKind" $ \case
    "image" -> pure MediaImage
    "video" -> pure MediaVideo
    other -> fail ("unknown media kind: " <> T.unpack other)

instance ToJSON ImageJob where
  toJSON j =
    object
      [ "message_id" .= j.messageId,
        "seg_index" .= j.segIndex,
        "url" .= j.url,
        "group_id" .= j.groupId,
        "sticker" .= j.sticker,
        "kind" .= j.kind
      ]

instance FromJSON ImageJob where
  parseJSON = withObject "ImageJob" $ \o ->
    ImageJob
      <$> o .: "message_id"
      <*> o .: "seg_index"
      <*> o .: "url"
      <*> o .:? "group_id"
      <*> o .:? "sticker"
      <*> o .: "kind"

-- | Walk a group message's segments and enqueue every downloadable image
-- (or mface). Segments without URLs (file-id only) are skipped silently —
-- 'get_image' fallback can come later.
enqueueImages ::
  (WithConnection :> es, IOE :> es) =>
  FetchSignal ->
  GroupMessage ->
  Eff es ()
enqueueImages sig gm =
  let MessageId mid = gm.messageId
      GroupId gid = gm.groupId
   in enqueueImagesFromNode sig mid (Just gid) gm.message

-- | Enqueue images belonging to an arbitrary 'message_id' — used by the
-- forward worker to feed synthetic ids for forwarded nodes.
enqueueImagesFromNode ::
  (WithConnection :> es, IOE :> es) =>
  FetchSignal ->
  Int64 ->
  Maybe Int64 ->
  [Segment] ->
  Eff es ()
enqueueImagesFromNode sig mid gid segs = do
  let jobs = mapMaybe pick (zip [0 ..] segs)
      pick (i, s) = case imageUrl s of
        Just u -> Just (ImageJob mid i u gid (stickerMeta s) MediaImage)
        Nothing -> (\u -> ImageJob mid i u gid Nothing MediaVideo) <$> videoUrl s
  traverse_ enqueueOne jobs
  liftIO (notifyFetch sig)
  where
    -- One segment holds at most one downloadable thing, so its index
    -- within the message is the whole natural key.
    enqueueOne j =
      enqueueJob JobImage (T.pack (show j.messageId <> ":" <> show j.segIndex)) j

-- | How many of a message's segments the worker will try to fetch —
-- i.e. how many 'message_images' rows will eventually exist for it
-- (barring download failures).  Lets 'Max.Prompt' wait for the
-- worker to catch up before embedding the trigger's images.
downloadableImageCount :: [Segment] -> Int
downloadableImageCount = length . mapMaybe imageUrl

-- | Same, for 'message_videos' rows.
downloadableVideoCount :: [Segment] -> Int
downloadableVideoCount = length . mapMaybe videoUrl

imageUrl :: Segment -> Maybe Text
imageUrl = \case
  SegImage info -> info.isiUrl
  SegOther "mface" (Object o) -> lookupString "url" o
  SegOther "image" (Object o) -> lookupString "url" o
  _ -> Nothing

-- | NapCat's container-local-path fallback isn't fetchable by us —
-- only real http(s) URLs enqueue.
videoUrl :: Segment -> Maybe Text
videoUrl = \case
  SegVideo v | Just u <- v.vsiUrl, "http" `T.isPrefixOf` u -> Just u
  _ -> Nothing

lookupString :: Text -> KM.KeyMap Value -> Maybe Text
lookupString k o = case KM.lookup (K.fromText k) o of
  Just (String s) | not (T.null s) -> Just s
  _ -> Nothing

-- | Lease per download.  Generous: the cap is 70 MiB over QQ's CDN,
-- and over-waiting only delays a retry, while under-waiting lets a
-- second worker start the same fetch.
imageLeaseSeconds :: Int
imageLeaseSeconds = 600

-- | Pool of @poolSize@ workers over the shared @fetch_jobs@ queue. HTTP
-- fetch, blob store, and DB writes all go through their respective
-- effects.  One job claimed at a time per worker: a download is slow
-- enough that batching would just hold leases on work nobody is doing.
imageWorker ::
  (Log :> es, Http :> es, Blob :> es, WithConnection :> es, Concurrent :> es, IOE :> es) =>
  Int ->
  FetchSignal ->
  Eff es ()
imageWorker poolSize sig = localDomain "image-worker" $ do
  logInfo "image worker pool started" $ object ["workers" .= poolSize]
  forConcurrently_ [1 .. poolSize] $ \wid ->
    localData [("w", toJSON (wid :: Int))] $
      runFetchLoop sig JobImage imageLeaseSeconds 1 processOne

processOne ::
  (Log :> es, Http :> es, Blob :> es, WithConnection :> es, IOE :> es) =>
  ImageJob ->
  Eff es (Either Text ())
processOne job = do
  logInfo "image downloading" $
    object
      [ "url" .= job.url,
        "message_id" .= job.messageId,
        "seg_index" .= job.segIndex
      ]
  r <- getBytes job.url maxBytes
  case r of
    -- Carries the URL because the queue's own failure log is generic;
    -- this is what someone reads when a picture never showed up.
    Left err ->
      pure (Left ("download failed (" <> job.url <> "): " <> err))
    Right (bytes, mime) -> do
      ref <- putBlob bytes
      let sha = blobRefSha256 ref
          rel = blobRefStoredPath ref
      case job.kind of
        MediaImage -> do
          recordImage sha mime (BS.length bytes) rel job
          for_ job.sticker (recordSticker sha job.groupId)
        MediaVideo -> do
          -- Probed duration rides into every label the prompt renders
          -- for this video — the model's own duration perception from
          -- sampled frames is unreliable.
          dur <- liftIO (probeVideoDuration bytes)
          -- QQ's CDN is sloppy about video content types; normalise
          -- anything that isn't video/* to mp4 (what QQ serves).
          recordVideo sha (if "video/" `T.isPrefixOf` mime then mime else "video/mp4") (BS.length bytes) rel dur job
      logInfo "media stored" $
        object
          [ "sha256_short" .= T.take 8 sha,
            "size" .= BS.length bytes,
            "mime" .= mime,
            "kind" .= T.pack (show job.kind),
            "message_id" .= job.messageId
          ]
      pure (Right ())
  where
    maxBytes = case job.kind of
      MediaImage -> 50 * 1024 * 1024
      -- Kimi's documented request-body ceiling is 100MB; base64 grows
      -- the video by 4/3, so 70MB raw ≈ 93MB on the wire, leaving a
      -- few MB for the prompt itself.  (DashScope's inline limit is
      -- far lower — 10MB — big videos there need their file-upload
      -- path, which we don't speak yet.)
      MediaVideo -> 70 * 1024 * 1024

recordImage ::
  (WithConnection :> es, IOE :> es) =>
  Text ->
  Text ->
  Int ->
  Text ->
  ImageJob ->
  Eff es ()
recordImage sha mime size rel job = do
  _ <-
    execute
      "INSERT INTO images (sha256, mime_type, bytes_size, local_path) \
      \ VALUES (?,?,?,?) ON CONFLICT (sha256) DO NOTHING"
      (sha, mime, fromIntegral size :: Int64, rel)
  _ <-
    execute
      "INSERT INTO message_images (message_id, sha256, seg_index) \
      \ VALUES (?,?,?) ON CONFLICT DO NOTHING"
      (job.messageId, sha, job.segIndex)
  pure ()

recordVideo ::
  (WithConnection :> es, IOE :> es) =>
  Text ->
  Text ->
  Int ->
  Text ->
  Maybe Double -> -- probed duration, seconds
  ImageJob ->
  Eff es ()
recordVideo sha mime size rel dur job = do
  _ <-
    execute
      "INSERT INTO videos (sha256, mime_type, bytes_size, local_path, duration_seconds) \
      \ VALUES (?,?,?,?,?) ON CONFLICT (sha256) DO NOTHING"
      (sha, mime, fromIntegral size :: Int64, rel, dur)
  _ <-
    execute
      "INSERT INTO message_videos (message_id, sha256, seg_index) \
      \ VALUES (?,?,?) ON CONFLICT DO NOTHING"
      (job.messageId, sha, job.segIndex)
  pure ()

-- | Probe a downloaded video's duration via ffprobe (temp-file
-- round-trip: the bytes are still in memory and mp4 needs seekable
-- input).  Best-effort — 'Nothing' just means labels omit the
-- duration.
probeVideoDuration :: BS.ByteString -> IO (Maybe Double)
probeVideoDuration bytes = do
  r <- try @IOException run
  pure $ case r of
    Right d -> d
    Left _ -> Nothing
  where
    run = withTempDirectory "max-vprobe-" $ \workspace -> do
      let path = workspace </> "input.bin"
      BS.writeFile path bytes
      (code, out, _) <-
        readProcessWithExitCode
          "ffprobe"
          ["-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", path]
          ""
      pure $ case code of
        ExitSuccess -> case reads (takeWhile (/= '\n') out) of
          [(d, "")] -> Just d
          _ -> Nothing
        ExitFailure _ -> Nothing
