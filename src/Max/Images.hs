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

import Control.Applicative ((<|>))
import Control.Exception (IOException, try)
import Data.Aeson
  ( FromJSON (..),
    Result (..),
    ToJSON (..),
    Value (Object, String),
    fromJSON,
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
import Max.Dispatch (DispatchMessage (..))
import Max.Effects.Blob (Blob, blobRefSha256, blobRefStoredPath, putBlob)
import Max.Effects.Http (Http, getQQMedia, renderDownloadError)
import Max.FetchQueue (FetchSignal, notifyFetch, runFetchLoop)
import Max.IR qualified as IR
import Max.Platform.Types (CanonicalMessageId (..))
import Max.Util (withTempDirectory)
import OneBot.Segment (ImageSegInfo (..), Segment (..), VideoSegInfo (..))
import OneBot.Types (GroupId (..))
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Process (readProcessWithExitCode)
import Text.Read (readMaybe)

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
  { canonicalMessageId :: !Int64,
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
      [ "canonical_message_id" .= j.canonicalMessageId,
        "seg_index" .= j.segIndex,
        "url" .= j.url,
        "group_id" .= j.groupId,
        "sticker" .= j.sticker,
        "kind" .= j.kind
      ]

instance FromJSON ImageJob where
  parseJSON = withObject "ImageJob" $ \o ->
    ImageJob
      <$> o .: "canonical_message_id"
      <*> o .: "seg_index"
      <*> o .: "url"
      <*> o .:? "group_id"
      <*> o .:? "sticker"
      <*> o .: "kind"

-- | Walk canonical media nodes and enqueue every directly downloadable image,
-- sticker, or video. The dispatch path never reconstructs OneBot segments.
enqueueImages ::
  (WithConnection :> es, IOE :> es) =>
  FetchSignal ->
  DispatchMessage ->
  Eff es ()
enqueueImages sig gm =
  let CanonicalMessageId mid = gm.canonicalId
      GroupId gid = gm.groupId
   in enqueueCanonicalMedia sig mid (Just gid) gm.body

enqueueCanonicalMedia ::
  (WithConnection :> es, IOE :> es) =>
  FetchSignal ->
  Int64 ->
  Maybe Int64 ->
  IR.Body 'IR.Canonical ->
  Eff es ()
enqueueCanonicalMedia sig mid gid body = do
  traverse_ enqueueOne (mapMaybe pick (zip [0 ..] body.nodes))
  liftIO (notifyFetch sig)
  where
    pick (i, IR.NMedia mRef meta) = do
      ref <- mRef
      url <- IR.mediaRefRemoteUrl ref
      kind <- case meta.kind of
        IR.MImage -> Just MediaImage
        IR.MSticker -> Just MediaImage
        IR.MVideo | "http" `T.isPrefixOf` T.toLower url -> Just MediaVideo
        _ -> Nothing
      let sticker = case (meta.kind, meta.raw >>= decodeSegment) of
            (IR.MSticker, Just segment) -> stickerMeta segment
            _ -> Nothing
      pure (ImageJob mid i url gid sticker kind)
    pick _ = Nothing

    decodeSegment raw = case fromJSON raw of
      Success segment -> Just segment
      Error _ -> Nothing

    enqueueOne job =
      enqueueJob JobImage (T.pack (show job.canonicalMessageId <> ":" <> show job.segIndex)) job

-- | Enqueue images belonging to an arbitrary canonical message — used by the
-- forward worker to feed the rows it just created for forwarded nodes.
--
-- Takes 'CanonicalMessageId' rather than a bare 'Int64' on purpose.  The job
-- ends up in @message_images.canonical_message_id@, which has a foreign key
-- to @messages@; the forward worker is the one caller that also holds a
-- compatibility id for the same node, and passing that one instead type-checked
-- perfectly and failed the constraint on every picture inside a forward.
enqueueImagesFromNode ::
  (WithConnection :> es, IOE :> es) =>
  FetchSignal ->
  CanonicalMessageId ->
  Maybe Int64 ->
  [Segment] ->
  Eff es ()
enqueueImagesFromNode sig (CanonicalMessageId mid) gid segs = do
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
      enqueueJob JobImage (T.pack (show j.canonicalMessageId <> ":" <> show j.segIndex)) j

-- | How many of a message's segments the worker will try to fetch —
-- i.e. how many 'message_images' rows will eventually exist for it
-- (barring download failures).  Lets 'Max.Prompt' wait for the
-- worker to catch up before embedding the trigger's images.
downloadableImageCount :: IR.Body 'IR.Canonical -> Int
downloadableImageCount = length . mapMaybe imageNodeUrl . (.nodes)
  where
    imageNodeUrl = \case
      IR.NMedia (Just ref) meta
        | meta.kind `elem` [IR.MImage, IR.MSticker] -> IR.mediaRefRemoteUrl ref
      _ -> Nothing

-- | Same, for 'message_videos' rows.
downloadableVideoCount :: IR.Body 'IR.Canonical -> Int
downloadableVideoCount = length . mapMaybe videoNodeUrl . (.nodes)
  where
    videoNodeUrl = \case
      IR.NMedia (Just ref) meta | meta.kind == IR.MVideo -> do
        url <- IR.mediaRefRemoteUrl ref
        if "http" `T.isPrefixOf` T.toLower url then Just url else Nothing
      _ -> Nothing

imageUrl :: Segment -> Maybe Text
imageUrl = \case
  SegImage info -> info.isiUrl
  SegOther "mface" (Object o) -> lookupString "url" o
  SegOther "image" (Object o) -> lookupString "url" o <|> lookupString "file" o
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
        "canonical_message_id" .= job.canonicalMessageId,
        "seg_index" .= job.segIndex
      ]
  r <- getQQMedia job.url maxBytes
  case r of
    -- Carries the URL because the queue's own failure log is generic;
    -- this is what someone reads when a picture never showed up.
    Left err ->
      pure (Left ("download failed (" <> job.url <> "): " <> renderDownloadError err))
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
            "canonical_message_id" .= job.canonicalMessageId
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
      "INSERT INTO message_images (canonical_message_id, sha256, seg_index) \
      \ VALUES (?,?,?) ON CONFLICT DO NOTHING"
      (job.canonicalMessageId, sha, job.segIndex)
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
      "INSERT INTO message_videos (canonical_message_id, sha256, seg_index) \
      \ VALUES (?,?,?) ON CONFLICT DO NOTHING"
      (job.canonicalMessageId, sha, job.segIndex)
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
        ExitSuccess -> readMaybe (takeWhile (/= '\n') out)
        ExitFailure _ -> Nothing
