-- |
-- Inbound non-image file worker.  Mirrors the shape of 'Max.Images'
-- but for 'SegFile' segments: each file goes through DB row insert
-- → @get_group_file_url@ RPC (if URL not already inline) → HTTP
-- fetch via the 'Http' effect → blob store → DB row update.
--
-- One worker is enough for now since file traffic is much lower
-- than image traffic; bump to a pool if it backs up.
module Max.Files
  ( enqueueFiles,
    fileWorker,
  )
where

import Data.Aeson (FromJSON (..), Result (..), ToJSON (..), fromJSON, withObject, (.:), (.:?))
import Data.ByteString qualified as BS
import Data.Foldable (traverse_)
import Data.Int (Int64)
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Effectful
import Effectful.Concurrent (Concurrent)
import Effectful.Log
import Effectful.PostgreSQL (WithConnection)
import Max.DB.FetchQueue (JobKind (JobFile), enqueueJob)
import Max.DB.Files qualified as DB
import Max.Dispatch (DispatchMessage (..))
import Max.Effects.Blob (Blob, blobRefSha256, putBlob)
import Max.Effects.Http (Http, getQQMedia, renderDownloadError)
import Max.Effects.PlatformQuery (PlatformQuery, queryGroupFileUrl)
import Max.FetchQueue (FetchSignal, notifyFetch, runFetchLoop)
import Max.IR (Body (..), MediaKind (MFile), MediaMeta (..), Node (NMedia), Phase (Canonical))
import Max.Platform.Failure (renderPlatformFailure)
import Max.Platform.Types (CanonicalMessageId (..))
import OneBot.Segment (FileSegInfo (..), Segment (..))
import OneBot.Types (GroupId (..), UserId (..))

-- | One inbound file pending fetch.
data FileJob = FileJob
  { fjFileId :: !Text,
    fjGroupId :: !Int64,
    fjMessageId :: !Int64,
    fjSenderUserId :: !Int64,
    fjFileName :: !Text,
    fjSizeHint :: !(Maybe Int64),
    fjUrlHint :: !(Maybe Text)
  }
  deriving stock (Show)

-- Persisted in @fetch_jobs@ rather than held in memory, so this is a
-- stored format: named fields, optional ones optional.
instance ToJSON FileJob where
  toJSON j =
    object
      [ "file_id" .= j.fjFileId,
        "group_id" .= j.fjGroupId,
        "message_id" .= j.fjMessageId,
        "sender_user_id" .= j.fjSenderUserId,
        "file_name" .= j.fjFileName,
        "size_hint" .= j.fjSizeHint,
        "url_hint" .= j.fjUrlHint
      ]

instance FromJSON FileJob where
  parseJSON = withObject "FileJob" $ \o ->
    FileJob
      <$> o .: "file_id"
      <*> o .: "group_id"
      <*> o .: "message_id"
      <*> o .: "sender_user_id"
      <*> o .: "file_name"
      <*> o .:? "size_hint"
      <*> o .:? "url_hint"

-- | Walk canonical media nodes and enqueue every QQ file. Also
-- inserts the catalog row up front so that @list_recent_files@ can
-- show the file even while the worker is still fetching the bytes.
enqueueFiles ::
  (WithConnection :> es, IOE :> es) =>
  FetchSignal ->
  DispatchMessage ->
  Eff es ()
enqueueFiles sig gm = do
  let CanonicalMessageId mid = gm.canonicalId
      GroupId gid = gm.groupId
      UserId uid = gm.userId
      jobs = mapMaybe (mkJob mid gid uid) gm.body.nodes
  -- Insert seen rows so list_recent_files works immediately.
  traverse_ insertJob jobs
  traverse_ enqueueOne jobs
  liftIO (notifyFetch sig)
  where
    insertJob j =
      DB.insertSeen
        j.fjFileId
        j.fjGroupId
        (Just j.fjMessageId)
        j.fjSenderUserId
        j.fjFileName
        j.fjSizeHint

    -- QQ's file_id is already the catalog's primary key.
    enqueueOne j = enqueueJob JobFile j.fjFileId j

mkJob :: Int64 -> Int64 -> Int64 -> Node 'Canonical -> Maybe FileJob
mkJob mid gid uid = \case
  NMedia _ meta | meta.kind == MFile -> do
    raw <- meta.raw
    SegFile fs <- case fromJSON raw of
      Success segment -> Just segment
      Error _ -> Nothing
    pure
      FileJob
        { fjFileId = fs.fsiFileId,
          fjGroupId = gid,
          fjMessageId = mid,
          fjSenderUserId = uid,
          fjFileName = fs.fsiName,
          fjSizeHint = fs.fsiSize,
          fjUrlHint = fs.fsiUrl
        }
  _ -> Nothing

--------------------------------------------------------------------------------
-- Worker.

-- | Files run to 200 MiB, so the lease has to cover a slow fetch of
-- one — over-waiting only delays a retry, under-waiting lets a second
-- claim start the same download.
fileLeaseSeconds :: Int
fileLeaseSeconds = 900

fileWorker ::
  ( Concurrent :> es,
    Log :> es,
    Http :> es,
    Blob :> es,
    WithConnection :> es,
    PlatformQuery :> es,
    IOE :> es
  ) =>
  FetchSignal ->
  Eff es ()
fileWorker sig = localDomain "file-worker" $ do
  logInfo_ "file worker started"
  runFetchLoop sig JobFile fileLeaseSeconds 1 processOne

processOne ::
  ( Log :> es,
    Http :> es,
    Blob :> es,
    WithConnection :> es,
    PlatformQuery :> es,
    IOE :> es
  ) =>
  FileJob ->
  Eff es (Either Text ())
processOne job = do
  logInfo "file processing" $
    object
      [ "file_id" .= job.fjFileId,
        "name" .= job.fjFileName,
        "group_id" .= job.fjGroupId
      ]
  resolveUrl job >>= \case
    Left err -> pure (Left err)
    Right u -> do
      r <- getQQMedia u maxBytes
      case r of
        Left err ->
          pure (Left ("download failed (" <> job.fjFileId <> "): " <> renderDownloadError err))
        Right (bytes, mime) -> do
          ref <- putBlob bytes
          let sha = blobRefSha256 ref
          DB.markStored
            job.fjFileId
            ref
            (Just mime)
            (fromIntegral (BS.length bytes))
          logInfo "file stored" $
            object
              [ "file_id" .= job.fjFileId,
                "sha256_short" .= T.take 8 sha,
                "size" .= BS.length bytes,
                "mime" .= mime
              ]
          pure (Right ())
  where
    -- 200 MiB cap. QQ caps group files at 100 MiB by default so this
    -- has slack; bump if you hit it.
    maxBytes = 200 * 1024 * 1024

-- | If NapCat inlined a URL on the segment, use it; otherwise call
-- @get_group_file_url@ and extract the @url@ field from the response.
-- A 'Left' is a retryable failure as far as the queue is concerned —
-- worth another go, since the commonest cause is NapCat not being
-- connected yet after a restart.
resolveUrl ::
  (PlatformQuery :> es) =>
  FileJob ->
  Eff es (Either Text Text)
resolveUrl job = case job.fjUrlHint of
  Just u | not (T.null u) -> pure (Right u)
  _ -> do
    result <- queryGroupFileUrl (GroupId job.fjGroupId) job.fjFileId
    pure $ case result of
      Left failure -> Left ("get_group_file_url failed: " <> renderPlatformFailure failure <> " (" <> job.fjFileId <> ")")
      Right url -> Right url
