-- |
-- CRUD for the 'group_files' catalog.  Rows are inserted on receipt
-- (still without sha256/local_path) and updated once the file
-- worker has streamed the bytes into the blob store.
module Max.DB.Files
  ( FileRecord (..),
    insertSeen,
    markStored,
    fileStored,
    fetchFilesForMessageInScope,
    listConversationFilesInScope,
  )
where

import Data.Int (Int64)
import Data.Text (Text)
import Database.PostgreSQL.Simple (Only (..))
import Effectful
import Effectful.PostgreSQL (WithConnection, execute, query)
import Max.Blob.Reference (BlobRef, blobRefSha256, blobRefStoredPath)
import Max.ConversationScope (ConversationScope, conversationStorageId)
import Max.File.Types (FileRecord (..))

-- | Idempotent insert on first sight.  The file worker fills in the
-- storage columns afterwards via 'markStored'.  Returning @()@; the
-- caller already knows the file_id.
insertSeen ::
  (WithConnection :> es, IOE :> es) =>
  Text -> -- file_id
  Int64 -> -- group_id
  Maybe Int64 -> -- canonical_message_id
  Int64 -> -- sender_user_id
  Text -> -- file_name
  Maybe Int64 -> -- bytes_size (if known at receipt)
  Eff es ()
insertSeen fid gid mid sender name size = do
  _ <-
    execute
      "INSERT INTO group_files \
      \  (file_id, group_id, canonical_message_id, sender_user_id, file_name, bytes_size) \
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
  BlobRef ->
  Maybe Text -> -- mime
  Int64 -> -- bytes
  Eff es ()
markStored fid ref mime size = do
  _ <-
    execute
      "UPDATE group_files \
      \  SET sha256 = ?, local_path = ?, mime_type = ?, \
      \      bytes_size = ?, fetched_at = now() \
      \ WHERE file_id = ?"
      (blobRefSha256 ref, blobRefStoredPath ref, mime, size, fid)
  pure ()

-- | All files attached to one message — used by the prompt builder
-- to enrich reply context (\"the user is asking about the file in
-- the message they quoted; here is its /chat path\").
fetchFilesForMessageInScope ::
  (WithConnection :> es, IOE :> es) =>
  ConversationScope ->
  Int64 ->
  Eff es [FileRecord]
fetchFilesForMessageInScope scope mid =
  query
    "SELECT file_id, group_id, canonical_message_id, sender_user_id, file_name, \
    \       mime_type, bytes_size, sha256, received_at, fetched_at \
    \  FROM group_files \
    \  WHERE group_id = ? AND canonical_message_id = ? \
    \  ORDER BY received_at ASC, file_id"
    (conversationStorageId scope, mid)

-- | Every file of this conversation grouped by message, each message's files
-- in the same order as 'fetchFilesForMessageInScope', so view names agree
-- with reply context. Files still downloading are included for numbering.
listConversationFilesInScope ::
  (WithConnection :> es, IOE :> es) =>
  ConversationScope ->
  Eff es [FileRecord]
listConversationFilesInScope scope =
  query
    "SELECT file_id, group_id, canonical_message_id, sender_user_id, file_name, \
    \       mime_type, bytes_size, sha256, received_at, fetched_at \
    \  FROM group_files \
    \  WHERE group_id = ? AND canonical_message_id IS NOT NULL \
    \  ORDER BY canonical_message_id, received_at ASC, file_id"
    (Only (conversationStorageId scope))

fileStored :: (WithConnection :> es, IOE :> es) => Text -> Eff es Bool
fileStored fileId = do
  rows <- query "SELECT 1 FROM group_files WHERE file_id=? AND sha256 IS NOT NULL" (Only fileId)
  pure (not (null (rows :: [Only Int])))
