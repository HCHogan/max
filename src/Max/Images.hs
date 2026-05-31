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
import Control.Exception (SomeAsyncException, SomeException, catch, fromException, throwIO, try)
import Control.Monad (forever)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.IO.Unlift (withRunInIO)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.Aeson (Value (Object, String))
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.Int (Int64)
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Database.PostgreSQL.Simple (execute)
import Log
import Max.DB.Connection (DbPool, withConn)
import Network.HTTP.Client
  ( Manager,
    brRead,
    newManager,
    parseRequest,
    responseBody,
    responseHeaders,
    responseStatus,
    withResponse,
  )
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Network.HTTP.Types.Header (hContentType)
import Network.HTTP.Types.Status (statusCode)
import OneBot.Event (GroupMessage (..))
import OneBot.Segment (Segment (..))
import OneBot.Types (MessageId (..))
import System.Directory (createDirectoryIfMissing, doesFileExist, renameFile)
import System.FilePath ((</>))
import System.IO qualified as IO

-- | One image (or mface) waiting to be fetched, hashed, and recorded.
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
-- (or mface) we can extract a URL for. Segments without URLs (file-id only)
-- are skipped silently — Turn 3 will add @get_image@-action fallback.
enqueueImages :: ImageQueue -> GroupMessage -> IO ()
enqueueImages q gm =
  let MessageId mid = gm.messageId
   in enqueueImagesFromNode q mid gm.message

-- | Enqueue image segments belonging to an arbitrary 'message_id' — used
-- by the forward worker, which feeds synthetic ids for forwarded nodes.
enqueueImagesFromNode :: ImageQueue -> Int64 -> [Segment] -> IO ()
enqueueImagesFromNode q mid segs = do
  let jobs = mapMaybe pick (zip [0 ..] segs)
      pick (i, s) = ImageJob mid i <$> imageUrl s
  atomically $ mapM_ (writeTQueue q) jobs

-- | Extract a URL from segment shapes NapCat actually emits.
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

-- | Single-threaded worker. Long-lived; spawn via 'withAsync' from Main.
-- One image-per-iteration, fail loud-but-isolated.
imageWorker :: FilePath -> DbPool -> ImageQueue -> LogT IO ()
imageWorker dir pool q = do
  mgr <- liftIO (newManager tlsManagerSettings)
  forever $ do
    job <- liftIO (atomically (readTQueue q))
    processOne mgr dir pool job
      `catchSync` \e ->
        logAttention "image worker crash" $
          object
            [ "error" .= T.pack (show e),
              "url" .= job.url,
              "message_id" .= job.messageId
            ]

processOne :: Manager -> FilePath -> DbPool -> ImageJob -> LogT IO ()
processOne mgr dir pool job = do
  r <- liftIO (download mgr job.url maxBytes)
  case r of
    Left err ->
      logAttention "image download failed" $
        object
          [ "error" .= err,
            "url" .= job.url,
            "message_id" .= job.messageId
          ]
    Right (bytes, mime) -> do
      let sha = sha256Hex bytes
          rel = relPath sha
      liftIO (writeBlob dir rel bytes)
      liftIO (recordImage pool sha mime (BS.length bytes) rel job)
      logTrace "image stored" $
        object
          [ "sha256" .= sha,
            "size" .= BS.length bytes,
            "mime" .= mime,
            "message_id" .= job.messageId
          ]
  where
    maxBytes = 50 * 1024 * 1024

-- | Stream-read body up to a byte limit; reject if exceeded. Returns the
-- bytes plus the primary Content-Type.
download :: Manager -> Text -> Int -> IO (Either Text (ByteString, Text))
download mgr url limit = do
  eres <- try $ do
    req <- parseRequest (T.unpack url)
    withResponse req mgr $ \resp -> do
      let sc = statusCode (responseStatus resp)
      if sc >= 400
        then pure (Left ("HTTP " <> T.pack (show sc)))
        else do
          let mime = case lookup hContentType (responseHeaders resp) of
                Just v -> primaryMime (TE.decodeUtf8 v)
                Nothing -> "application/octet-stream"
          chunks <- readChunks (responseBody resp) limit []
          pure $ fmap (,mime) chunks
  case eres :: Either SomeException (Either Text (ByteString, Text)) of
    Right r -> pure r
    Left e -> pure (Left (T.pack (show e)))
  where
    readChunks body remaining acc
      | remaining <= 0 = pure (Left "exceeded 50 MiB size limit")
      | otherwise = do
          chunk <- brRead body
          if BS.null chunk
            then pure (Right (BS.concat (reverse acc)))
            else readChunks body (remaining - BS.length chunk) (chunk : acc)

primaryMime :: Text -> Text
primaryMime = T.strip . fst . T.breakOn ";"

sha256Hex :: ByteString -> Text
sha256Hex = TE.decodeUtf8 . B16.encode . SHA256.hash

-- | @ab/abcdef...@ — one level of hex-prefix bucketing under the images
-- root. One level is plenty until well past 1M files.
relPath :: Text -> FilePath
relPath sha = T.unpack (T.take 2 sha) </> T.unpack sha

writeBlob :: FilePath -> FilePath -> ByteString -> IO ()
writeBlob root rel bytes = do
  let final = root </> rel
  exists <- doesFileExist final
  if exists
    then pure ()
    else do
      let subdir = root </> take 2 rel
      createDirectoryIfMissing True subdir
      let tmp = final <> ".tmp"
      IO.withBinaryFile tmp IO.WriteMode (`BS.hPut` bytes)
      renameFile tmp final

recordImage :: DbPool -> Text -> Text -> Int -> FilePath -> ImageJob -> IO ()
recordImage pool sha mime size rel job = withConn pool $ \c -> do
  _ <-
    execute
      c
      "INSERT INTO images (sha256, mime_type, bytes_size, local_path) \
      \ VALUES (?,?,?,?) ON CONFLICT (sha256) DO NOTHING"
      (sha, mime, fromIntegral size :: Int64, T.pack rel)
  _ <-
    execute
      c
      "INSERT INTO message_images (message_id, sha256, seg_index) \
      \ VALUES (?,?,?) ON CONFLICT DO NOTHING"
      (job.messageId, sha, job.segIndex)
  pure ()

catchSync :: LogT IO a -> (SomeException -> LogT IO a) -> LogT IO a
catchSync act h = withRunInIO $ \run ->
  run act `catch` \e ->
    case fromException e :: Maybe SomeAsyncException of
      Just _ -> throwIO e
      Nothing -> run (h e)
