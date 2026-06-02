module Max.Images
  ( ImageJob (..),
    ImageQueue,
    newImageQueue,
    enqueueImages,
    enqueueImagesFromNode,
    imageWorker,
  )
where

import Control.Concurrent.STM (TQueue, atomically, newTQueueIO, readTQueue, writeTQueue)
import Control.Exception (SomeException)
import Control.Monad (forever)
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
import Max.Effects.Blob (Blob, blobPath, putBlob)
import Max.Effects.Http (Http, getBytes)
import Max.Util (catchSync)
import OneBot.Event (GroupMessage (..))
import OneBot.Segment (Segment (..))
import OneBot.Types (MessageId (..))

-- | One image (or mface) waiting to be fetched and recorded.
data ImageJob = ImageJob
  { messageId :: !Int64,
    segIndex :: !Int,
    url :: !Text
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
   in enqueueImagesFromNode q mid gm.message

-- | Enqueue images belonging to an arbitrary 'message_id' — used by the
-- forward worker to feed synthetic ids for forwarded nodes.
enqueueImagesFromNode :: ImageQueue -> Int64 -> [Segment] -> IO ()
enqueueImagesFromNode q mid segs = do
  let jobs = mapMaybe pick (zip [0 ..] segs)
      pick (i, s) = ImageJob mid i <$> imageUrl s
  atomically $ mapM_ (writeTQueue q) jobs

imageUrl :: Segment -> Maybe Text
imageUrl = \case
  SegImage (Just u) -> Just u
  SegOther "mface" (Object o) -> lookupString "url" o
  SegOther "image" (Object o) -> lookupString "url" o
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
            "message_id" .= job.messageId
          ]
    Right (bytes, mime) -> do
      sha <- putBlob bytes
      rel <- blobPath sha
      recordImage sha mime (BS.length bytes) rel job
      logInfo "image stored" $
        object
          [ "sha256_short" .= T.take 8 sha,
            "size" .= BS.length bytes,
            "mime" .= mime,
            "message_id" .= job.messageId
          ]
  where
    maxBytes = 50 * 1024 * 1024

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
