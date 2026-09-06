-- | Download-catalog facts; no database or host-path capability.
module Max.File.Types (FileRecord (..)) where

import Data.Int (Int64)
import Data.Text (Text)
import Data.Time (UTCTime)
import Database.PostgreSQL.Simple.FromRow (FromRow (..), field)
import Max.Blob.Reference (BlobRef, blobRefFromSha256)

-- | One row in 'group_files'.  Fields after 'fileName' may be
-- 'Nothing' until the file worker has finished fetching.
data FileRecord = FileRecord
  { frFileId :: !Text,
    frGroupId :: !Int64,
    frCanonicalMessageId :: !(Maybe Int64),
    frSenderUserId :: !Int64,
    frFileName :: !Text,
    frMimeType :: !(Maybe Text),
    frBytesSize :: !(Maybe Int64),
    frBlobRef :: !(Maybe BlobRef),
    frReceivedAt :: !UTCTime,
    frFetchedAt :: !(Maybe UTCTime)
  }
  deriving stock (Show)

instance FromRow FileRecord where
  fromRow = do
    fileId <- field
    groupId <- field
    messageId <- field
    senderUserId <- field
    fileName <- field
    mimeType <- field
    bytesSize <- field
    sha <- field
    receivedAt <- field
    fetchedAt <- field
    pure
      FileRecord
        { frFileId = fileId,
          frGroupId = groupId,
          frCanonicalMessageId = messageId,
          frSenderUserId = senderUserId,
          frFileName = fileName,
          frMimeType = mimeType,
          frBytesSize = bytesSize,
          frBlobRef = sha >>= blobRefFromSha256,
          frReceivedAt = receivedAt,
          frFetchedAt = fetchedAt
        }
