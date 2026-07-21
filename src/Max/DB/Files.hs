-- |
-- CRUD for the 'group_files' catalog.  Rows are inserted on receipt
-- (still without sha256/local_path) and updated once the file
-- worker has streamed the bytes into the blob store.
module Max.DB.Files
  ( FileRecord (..),
    insertSeen,
    markStored,
    fetchByFileId,
    fetchFilesForMessage,
    listRecentInGroup,
  )
where

import Data.Int (Int64)
import Data.Text (Text)
import Data.Time (UTCTime)
import Database.PostgreSQL.Simple (FromRow, Only (..))
import Database.PostgreSQL.Simple.FromRow (field, fromRow)
import Effectful
import Effectful.PostgreSQL (WithConnection, execute, query)

-- | One row in 'group_files'.  Fields after 'fileName' may be
-- 'Nothing' until the file worker has finished fetching.
data FileRecord = FileRecord
  { frFileId :: !Text,
    frGroupId :: !Int64,
    frMessageId :: !(Maybe Int64),
    frSenderUserId :: !Int64,
    frFileName :: !Text,
    frMimeType :: !(Maybe Text),
    frBytesSize :: !(Maybe Int64),
    frSha256 :: !(Maybe Text),
    frLocalPath :: !(Maybe Text),
    frReceivedAt :: !UTCTime,
    frFetchedAt :: !(Maybe UTCTime)
  }
  deriving stock (Show)

instance FromRow FileRecord where
  fromRow =
    FileRecord
      <$> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field

-- | Idempotent insert on first sight.  The file worker fills in the
-- storage columns afterwards via 'markStored'.  Returning @()@; the
-- caller already knows the file_id.
insertSeen ::
  (WithConnection :> es, IOE :> es) =>
  Text -> -- file_id
  Int64 -> -- group_id
  Maybe Int64 -> -- message_id
  Int64 -> -- sender_user_id
  Text -> -- file_name
  Maybe Int64 -> -- bytes_size (if known at receipt)
  Eff es ()
insertSeen fid gid mid sender name size = do
  _ <-
    execute
      "INSERT INTO group_files \
      \  (file_id, group_id, message_id, sender_user_id, file_name, bytes_size) \
      \ VALUES (?,?,?,?,?,?) \
      \ ON CONFLICT (file_id) DO NOTHING"
      (fid, gid, mid, sender, name, size)
  pure ()

-- | Patch in sha256 / local_path / fetched_at / mime_type after the
-- worker downloads.  Bytes_size also overwritten in case the seen-time
-- value was a guess.
markStored ::
  (WithConnection :> es, IOE :> es) =>
  Text -> -- file_id
  Text -> -- sha256
  Text -> -- local_path (relative to blob root)
  Maybe Text -> -- mime
  Int64 -> -- bytes
  Eff es ()
markStored fid sha rel mime size = do
  _ <-
    execute
      "UPDATE group_files \
      \  SET sha256 = ?, local_path = ?, mime_type = ?, \
      \      bytes_size = ?, fetched_at = now() \
      \ WHERE file_id = ?"
      (sha, rel, mime, size, fid)
  pure ()

fetchByFileId ::
  (WithConnection :> es, IOE :> es) =>
  Text ->
  Eff es (Maybe FileRecord)
fetchByFileId fid = do
  rows <-
    query
      "SELECT file_id, group_id, message_id, sender_user_id, file_name, \
      \       mime_type, bytes_size, sha256, local_path, received_at, fetched_at \
      \  FROM group_files \
      \  WHERE file_id = ? \
      \  LIMIT 1"
      (Only fid)
  pure $ case rows of
    (r : _) -> Just r
    [] -> Nothing

-- | All files attached to one message — used by the prompt builder
-- to enrich reply context (\"the user is asking about the file in
-- the message they quoted; here are its file_ids\").
fetchFilesForMessage ::
  (WithConnection :> es, IOE :> es) =>
  Int64 ->
  Eff es [FileRecord]
fetchFilesForMessage mid =
  query
    "SELECT file_id, group_id, message_id, sender_user_id, file_name, \
    \       mime_type, bytes_size, sha256, local_path, received_at, fetched_at \
    \  FROM group_files \
    \  WHERE message_id = ? \
    \  ORDER BY received_at ASC"
    (Only mid)

-- | Newest @n@ files in @gid@, ordered by receipt time descending.
listRecentInGroup ::
  (WithConnection :> es, IOE :> es) =>
  Int64 -> -- group_id
  Int -> -- limit
  Eff es [FileRecord]
listRecentInGroup gid lim = do
  query
    "SELECT file_id, group_id, message_id, sender_user_id, file_name, \
    \       mime_type, bytes_size, sha256, local_path, received_at, fetched_at \
    \  FROM group_files \
    \  WHERE group_id = ? \
    \  ORDER BY received_at DESC \
    \  LIMIT ?"
    (gid, lim)
