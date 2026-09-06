-- | Validated content addresses. This module neither reads nor writes files.
module Max.Blob.Reference (BlobRef, blobRefFromSha256, blobRefForBytes, blobRefSha256, blobRefStoredPath) where

import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString (ByteString)
import Data.ByteString.Base16 qualified as B16
import Data.Char (isDigit)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE

-- | Opaque content address for one object in the blob store.  Keeping this
-- distinct from database paths and arbitrary text prevents ordinary consumers
-- from escaping the store boundary by joining paths themselves.
newtype BlobRef = BlobRef {blobRefSha256 :: Text}
  deriving stock (Show, Eq, Ord)

-- | Validate a sha256 loaded from durable storage before it becomes a
-- 'BlobRef'.  The store writes lowercase hexadecimal addresses; rejecting
-- anything else also rules out absolute paths and @..@ traversal.
blobRefFromSha256 :: Text -> Maybe BlobRef
blobRefFromSha256 sha
  | T.length sha == 64 && T.all isLowerHex sha = Just (BlobRef sha)
  | otherwise = Nothing
  where
    isLowerHex c = isDigit c || ('a' <= c && c <= 'f')

-- | Legacy relative path persisted in @local_path@ columns.  New readers use
-- the sha256 as a 'BlobRef'; producers still fill this field until a schema
-- migration removes it.
blobRefStoredPath :: BlobRef -> Text
blobRefStoredPath ref = T.take 2 ref.blobRefSha256 <> "/" <> ref.blobRefSha256

blobRefForBytes :: ByteString -> BlobRef
blobRefForBytes = BlobRef . TE.decodeUtf8 . B16.encode . SHA256.hash
