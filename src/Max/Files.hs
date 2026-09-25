-- | Fetch inbound files into the blob store and record their metadata.
module Max.Files
  ( enqueueFiles,
    fileWorker,
  )
where

import Data.Aeson (Result (..), fromJSON)
import Data.ByteString qualified as BS
import Data.Foldable (for_, traverse_)
import Data.Int (Int64)
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Effectful
import Effectful.Log
import Effectful.PostgreSQL (WithConnection)
import Max.ConversationScope (conversationScopeFor)
import Max.DB.Files qualified as DB
import Max.DB.MediaMissing (parkFetch)
import Max.Dispatch (DispatchMessage (..))
import Max.Effects.Blob (Blob, blobRefSha256, putBlob)
import Max.Effects.ChatView (ChatView, linkChatMedia)
import Max.Effects.Http (Http, getQQMedia, renderDownloadError)
import Max.Effects.PlatformQuery (PlatformQuery, queryGroupFileUrl)
import Max.FetchQueue (FetchPriority (..), FetchSignal, FileJob (..), JobKind (JobFile), enqueueFetch, notifyFetch, runFetchLoop)
import Max.IR (Body (..), MediaKind (MFile), MediaMeta (..), Node (NMedia), Phase (Canonical))
import Max.Platform.Failure (renderPlatformFailure)
import Max.Platform.Types (CanonicalMessageId (..))
import Max.Sandbox.Chat (chatFileNames)
import OneBot.Segment (FileSegInfo (..), Segment (..))
import OneBot.Types (GroupId (..), UserId (..))

-- | Walk canonical media nodes and enqueue every QQ file. Also
-- inserts the catalog row up front, so reply context can show the file as
-- still downloading while the worker fetches the bytes.
enqueueFiles ::
  (WithConnection :> es, IOE :> es) =>
  FetchPriority ->
  FetchSignal ->
  DispatchMessage ->
  Eff es ()
enqueueFiles priority sig gm = do
  let CanonicalMessageId mid = gm.canonicalId
      GroupId gid = gm.groupId
      UserId uid = gm.userId
      jobs = mapMaybe (mkJob mid gid uid) gm.body.nodes
  -- Insert seen rows so reply context lists them immediately.
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
    enqueueOne j = enqueueFetch sig priority JobFile j.fjFileId j

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

fileWorker ::
  ( Log :> es,
    Http :> es,
    Blob :> es,
    ChatView :> es,
    WithConnection :> es,
    PlatformQuery :> es,
    IOE :> es
  ) =>
  FetchSignal ->
  Eff es ()
fileWorker sig = localDomain "file-worker" $ do
  logInfo_ "file worker started"
  runFetchLoop sig JobFile parkFetch processOne

processOne ::
  ( Log :> es,
    Http :> es,
    Blob :> es,
    ChatView :> es,
    WithConnection :> es,
    PlatformQuery :> es,
    IOE :> es
  ) =>
  FileJob ->
  Eff es (Either Text ())
processOne job = do
  stored <- DB.fileStored job.fjFileId
  if stored then pure (Right ()) else downloadFile job

downloadFile :: (Log :> es, Http :> es, Blob :> es, ChatView :> es, WithConnection :> es, PlatformQuery :> es, IOE :> es) => FileJob -> Eff es (Either Text ())
downloadFile job = do
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
          -- Numbering depends on every file of the message, as in reply context.
          let group = GroupId job.fjGroupId
          siblings <- DB.fetchFilesForMessageInScope (conversationScopeFor group) job.fjMessageId
          for_ [name | (name, record) <- zip (chatFileNames job.fjMessageId (map (.frFileName) siblings)) siblings, record.frFileId == job.fjFileId] $ \name ->
            linkChatMedia group name ref
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
