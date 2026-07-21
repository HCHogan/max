-- |
-- Inbound non-image file worker.  Mirrors the shape of 'Max.Images'
-- but for 'SegFile' segments: each file goes through DB row insert
-- → @get_group_file_url@ RPC (if URL not already inline) → HTTP
-- fetch via the 'Http' effect → blob store → DB row update.
--
-- One worker is enough for now since file traffic is much lower
-- than image traffic; bump to a pool if it backs up.
module Max.Files
  ( FileQueue,
    newFileQueue,
    enqueueFiles,
    fileWorker,
  )
where

import Control.Concurrent.STM
import Control.Exception (SomeException)
import Control.Monad (forever)
import Data.Foldable (traverse_)
import Data.Aeson (Value, withObject, (.:))
import Data.Aeson.Types (Parser, parseEither)
import Data.ByteString qualified as BS
import Data.Int (Int64)
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Effectful
import Effectful.Log
import Effectful.PostgreSQL (WithConnection)
import Max.DB.Files qualified as DB
import Max.Effects.Blob (Blob, blobPath, putBlob)
import Max.Effects.Http (Http, getBytes)
import Max.Effects.NapCat (NapCat, callAction)
import Max.Util (catchSync)
import OneBot.Action (Action (GetGroupFileUrl), Response (..))
import OneBot.Event (GroupMessage (..))
import OneBot.Segment (FileSegInfo (..), Segment (..))
import OneBot.Types (GroupId (..), MessageId (..), UserId (..))

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

type FileQueue = TQueue FileJob

newFileQueue :: IO FileQueue
newFileQueue = newTQueueIO

-- | Walk a group message's segments and enqueue every file.  Also
-- inserts the catalog row up front so that @list_recent_files@ can
-- show the file even while the worker is still fetching the bytes.
enqueueFiles ::
  (WithConnection :> es, IOE :> es) =>
  FileQueue ->
  GroupMessage ->
  Eff es ()
enqueueFiles q gm = do
  let MessageId mid = gm.messageId
      GroupId gid = gm.groupId
      UserId uid = gm.userId
      jobs = mapMaybe (mkJob mid gid uid) gm.message
  -- Insert seen rows so list_recent_files works immediately.
  traverse_ insertJob jobs
  liftIO . atomically $ traverse_ (writeTQueue q) jobs
  where
    insertJob j =
      DB.insertSeen
        j.fjFileId
        j.fjGroupId
        (Just j.fjMessageId)
        j.fjSenderUserId
        j.fjFileName
        j.fjSizeHint

mkJob :: Int64 -> Int64 -> Int64 -> Segment -> Maybe FileJob
mkJob mid gid uid = \case
  SegFile fs ->
    Just
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

fileWorker ::
  ( Log :> es,
    Http :> es,
    Blob :> es,
    WithConnection :> es,
    NapCat :> es,
    IOE :> es
  ) =>
  FileQueue ->
  Eff es ()
fileWorker q = localDomain "file-worker" $ do
  logInfo_ "file worker started"
  forever $ do
    job <- liftIO (atomically (readTQueue q))
    logInfo "file processing" $
      object
        [ "file_id" .= job.fjFileId,
          "name" .= job.fjFileName,
          "group_id" .= job.fjGroupId
        ]
    processOne job
      `catchSync` \e ->
        logAttention "file worker crash" $
          object
            [ "error" .= T.pack (show (e :: SomeException)),
              "file_id" .= job.fjFileId
            ]

processOne ::
  ( Log :> es,
    Http :> es,
    Blob :> es,
    WithConnection :> es,
    NapCat :> es,
    IOE :> es
  ) =>
  FileJob ->
  Eff es ()
processOne job = do
  url <- resolveUrl job
  case url of
    Nothing -> pure () -- already logged inside resolveUrl
    Just u -> do
      r <- getBytes u maxBytes
      case r of
        Left err ->
          logAttention "file download failed" $
            object
              [ "error" .= err,
                "file_id" .= job.fjFileId,
                "url" .= u
              ]
        Right (bytes, mime) -> do
          sha <- putBlob bytes
          rel <- blobPath sha
          DB.markStored
            job.fjFileId
            sha
            (T.pack rel)
            (Just mime)
            (fromIntegral (BS.length bytes))
          logInfo "file stored" $
            object
              [ "file_id" .= job.fjFileId,
                "sha256_short" .= T.take 8 sha,
                "size" .= BS.length bytes,
                "mime" .= mime
              ]
  where
    -- 200 MiB cap. QQ caps group files at 100 MiB by default so this
    -- has slack; bump if you hit it.
    maxBytes = 200 * 1024 * 1024

-- | If NapCat inlined a URL on the segment, use it; otherwise call
-- @get_group_file_url@ and extract the @url@ field from the response.
-- Returns 'Nothing' (with attention log) if neither path yields a URL.
resolveUrl ::
  (Log :> es, NapCat :> es) =>
  FileJob ->
  Eff es (Maybe Text)
resolveUrl job = case job.fjUrlHint of
  Just u | not (T.null u) -> pure (Just u)
  _ -> do
    let timeoutMs = 30000
    eres <- callAction (GetGroupFileUrl (GroupId job.fjGroupId) job.fjFileId) timeoutMs
    case eres of
      Left err -> do
        logAttention "get_group_file_url failed" $
          object ["error" .= err, "file_id" .= job.fjFileId]
        pure Nothing
      Right (Response _ rc payload _)
        | rc /= 0 -> do
            logAttention "get_group_file_url bad retcode" $
              object ["retcode" .= rc, "file_id" .= job.fjFileId]
            pure Nothing
        | otherwise -> case parseEither extractUrl payload of
            Left perr -> do
              logAttention "get_group_file_url parse error" $
                object ["error" .= T.pack perr, "file_id" .= job.fjFileId]
              pure Nothing
            Right u -> pure (Just u)

extractUrl :: Value -> Parser Text
extractUrl = withObject "GroupFileUrl" $ \o -> o .: "url"
