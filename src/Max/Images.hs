module Max.Images
  ( ImageJob (..),
    MediaKind (..),
    enqueueImages,
    downloadableImageCount,
    downloadableVideoCount,
    imageWorker,
  )
where

import Control.Exception (IOException, try)
import Data.Aeson (Result (..), fromJSON, toJSON)
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
import Max.DB.Media (videoMime, viewableImageMime)
import Max.DB.MediaMissing (parkFetch, storedMedia)
import Max.DB.Stickers (recordSticker, stickerMeta)
import Max.DB.Transaction (withTransaction)
import Max.Dispatch (DispatchMessage (..))
import Max.Effects.Blob (Blob, blobRefSha256, blobRefStoredPath, putBlob)
import Max.Effects.ChatView (ChatView, linkChatMedia)
import Max.Effects.Http (Http, getQQMedia, renderDownloadError)
import Max.FetchQueue (FetchPriority (..), FetchSignal, ImageJob (..), JobKind (JobImage), MediaKind (..), enqueueFetch, notifyFetch, runFetchLoop)
import Max.IR qualified as IR
import Max.Platform.Types (CanonicalMessageId (..))
import Max.Sandbox.Chat (ChatKind (..), chatMediaName)
import Max.Util (withTempDirectory)
import OneBot.Types (GroupId (..))
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Process (readProcessWithExitCode)
import Text.Read (readMaybe)

-- | Walk canonical media nodes and enqueue every directly downloadable image,
-- sticker, or video. The dispatch path never reconstructs OneBot segments.
enqueueImages ::
  (IOE :> es) =>
  FetchPriority ->
  FetchSignal ->
  DispatchMessage ->
  Eff es ()
enqueueImages priority sig gm =
  let CanonicalMessageId mid = gm.canonicalId
      GroupId gid = gm.groupId
   in enqueueCanonicalMedia priority sig mid (Just gid) gm.body

enqueueCanonicalMedia ::
  (IOE :> es) =>
  FetchPriority ->
  FetchSignal ->
  Int64 ->
  Maybe Int64 ->
  IR.Body 'IR.Canonical ->
  Eff es ()
enqueueCanonicalMedia priority sig mid gid body = do
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
      enqueueFetch sig priority JobImage (T.pack (show job.canonicalMessageId <> ":" <> show job.segIndex)) job

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

imageWorker ::
  (Log :> es, Http :> es, Blob :> es, ChatView :> es, WithConnection :> es, Concurrent :> es, IOE :> es) =>
  Int ->
  FetchSignal ->
  Eff es ()
imageWorker poolSize sig = localDomain "image-worker" $ do
  logInfo "image worker pool started" $ object ["workers" .= poolSize]
  forConcurrently_ [1 .. poolSize] $ \wid ->
    localData [("w", toJSON (wid :: Int))] $
      runFetchLoop sig JobImage parkFetch processOne

processOne ::
  (Log :> es, Http :> es, Blob :> es, ChatView :> es, WithConnection :> es, IOE :> es) =>
  ImageJob ->
  Eff es (Either Text ())
processOne job = do
  existing <- storedMedia job.kind job.canonicalMessageId job.segIndex
  case existing of
    Just _ -> pure (Right ())
    Nothing -> downloadMedia job

downloadMedia :: (Log :> es, Http :> es, Blob :> es, ChatView :> es, WithConnection :> es, IOE :> es) => ImageJob -> Eff es (Either Text ())
downloadMedia job = do
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
        MediaImage -> withTransaction $ do
          recordImage sha mime (BS.length bytes) rel job
          for_ job.sticker (recordSticker sha job.groupId)
        MediaVideo -> do
          -- Probed duration rides into every label the prompt renders
          -- for this video — the model's own duration perception from
          -- sampled frames is unreliable.
          dur <- liftIO (probeVideoDuration bytes)
          -- QQ's CDN is sloppy about video content types; normalise
          -- anything that isn't video/* to mp4 (what QQ serves).
          withTransaction $ recordVideo sha (if "video/" `T.isPrefixOf` mime then mime else "video/mp4") (BS.length bytes) rel dur job
      -- Name it in the conversation's sandbox view by its recorded row, the
      -- rule backfill uses; stickers stay out.
      recorded <- case job.kind of
        MediaImage -> fmap (chatMediaName ChatImage job.canonicalMessageId job.segIndex . Just) <$> viewableImageMime sha
        MediaVideo -> fmap (chatMediaName ChatVideo job.canonicalMessageId job.segIndex . Just) <$> videoMime sha
      for_ ((,) <$> job.groupId <*> recorded) $ \(group, name) -> linkChatMedia (GroupId group) name ref
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
