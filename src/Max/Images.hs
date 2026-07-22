module Max.Images
  ( ImageJob (..),
    MediaKind (..),
    ImageQueue,
    newImageQueue,
    enqueueImages,
    enqueueImagesFromNode,
    downloadableImageCount,
    downloadableVideoCount,
    imageWorker,
  )
where

import Control.Concurrent.STM (TQueue, atomically, newTQueueIO, readTQueue, writeTQueue)
import Control.Exception (SomeException)
import Control.Monad (forever)
import Data.Foldable (for_, traverse_)
import Data.Aeson (Value (Object, String), toJSON)
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString qualified as BS
import Data.Int (Int64)
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Effectful
import Effectful.Concurrent.Async (Concurrent, forConcurrently_)
import Effectful.Log
import Effectful.PostgreSQL (WithConnection, execute)
import Max.DB.Stickers (StickerMeta, recordSticker, stickerMeta)
import Max.Effects.Blob (Blob, blobPath, putBlob)
import Max.Effects.Http (Http, getBytes)
import Max.Util (catchSync)
import OneBot.Event (GroupMessage (..))
import OneBot.Segment (ImageSegInfo (..), Segment (..), VideoSegInfo (..))
import OneBot.Types (GroupId (..), MessageId (..))

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

type ImageQueue = TQueue ImageJob

newImageQueue :: IO ImageQueue
newImageQueue = newTQueueIO

-- | Walk a group message's segments and enqueue every downloadable image
-- (or mface). Segments without URLs (file-id only) are skipped silently —
-- 'get_image' fallback can come later.
enqueueImages :: ImageQueue -> GroupMessage -> IO ()
enqueueImages q gm =
  let MessageId mid = gm.messageId
      GroupId gid = gm.groupId
   in enqueueImagesFromNode q mid (Just gid) gm.message

-- | Enqueue images belonging to an arbitrary 'message_id' — used by the
-- forward worker to feed synthetic ids for forwarded nodes.
enqueueImagesFromNode :: ImageQueue -> Int64 -> Maybe Int64 -> [Segment] -> IO ()
enqueueImagesFromNode q mid gid segs = do
  let jobs = mapMaybe pick (zip [0 ..] segs)
      pick (i, s) = case imageUrl s of
        Just u -> Just (ImageJob mid i u gid (stickerMeta s) MediaImage)
        Nothing -> (\u -> ImageJob mid i u gid Nothing MediaVideo) <$> videoUrl s
  atomically $ traverse_ (writeTQueue q) jobs

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

-- | Pool of @poolSize@ workers reading from a shared queue. HTTP fetch,
-- blob store, and DB writes all go through their respective effects.
imageWorker ::
  (Log :> es, Http :> es, Blob :> es, WithConnection :> es, Concurrent :> es, IOE :> es) =>
  Int ->
  ImageQueue ->
  Eff es ()
imageWorker poolSize q = localDomain "image-worker" $ do
  logInfo "image worker pool started" $ object ["workers" .= poolSize]
  forConcurrently_ [1 .. poolSize] $ \wid ->
    localData [("w", toJSON (wid :: Int))] $
      workerLoop q

workerLoop ::
  (Log :> es, Http :> es, Blob :> es, WithConnection :> es, IOE :> es) =>
  ImageQueue ->
  Eff es ()
workerLoop q = forever $ do
  job <- liftIO (atomically (readTQueue q))
  logInfo "image downloading" $
    object
      [ "url" .= job.url,
        "message_id" .= job.messageId,
        "seg_index" .= job.segIndex
      ]
  processOne job
    `catchSync` \e ->
      logAttention "image worker crash" $
        object
          [ "error" .= T.pack (show (e :: SomeException)),
            "url" .= job.url,
            "message_id" .= job.messageId
          ]

processOne ::
  (Log :> es, Http :> es, Blob :> es, WithConnection :> es, IOE :> es) =>
  ImageJob ->
  Eff es ()
processOne job = do
  r <- getBytes job.url maxBytes
  case r of
    Left err ->
      logAttention "image download failed" $
        object
          [ "error" .= err,
            "url" .= job.url,
            "kind" .= T.pack (show job.kind),
            "message_id" .= job.messageId
          ]
    Right (bytes, mime) -> do
      sha <- putBlob bytes
      rel <- blobPath sha
      case job.kind of
        MediaImage -> do
          recordImage sha mime (BS.length bytes) rel job
          for_ job.sticker (recordSticker sha job.groupId)
        MediaVideo ->
          -- QQ's CDN is sloppy about video content types; normalise
          -- anything that isn't video/* to mp4 (what QQ serves).
          recordVideo sha (if "video/" `T.isPrefixOf` mime then mime else "video/mp4") (BS.length bytes) rel job
      logInfo "media stored" $
        object
          [ "sha256_short" .= T.take 8 sha,
            "size" .= BS.length bytes,
            "mime" .= mime,
            "kind" .= T.pack (show job.kind),
            "message_id" .= job.messageId
          ]
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
  FilePath ->
  ImageJob ->
  Eff es ()
recordImage sha mime size rel job = do
  _ <-
    execute
      "INSERT INTO images (sha256, mime_type, bytes_size, local_path) \
      \ VALUES (?,?,?,?) ON CONFLICT (sha256) DO NOTHING"
      (sha, mime, fromIntegral size :: Int64, T.pack rel)
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
  FilePath ->
  ImageJob ->
  Eff es ()
recordVideo sha mime size rel job = do
  _ <-
    execute
      "INSERT INTO videos (sha256, mime_type, bytes_size, local_path) \
      \ VALUES (?,?,?,?) ON CONFLICT (sha256) DO NOTHING"
      (sha, mime, fromIntegral size :: Int64, T.pack rel)
  _ <-
    execute
      "INSERT INTO message_videos (message_id, sha256, seg_index) \
      \ VALUES (?,?,?) ON CONFLICT DO NOTHING"
      (job.messageId, sha, job.segIndex)
  pure ()
