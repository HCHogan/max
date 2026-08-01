{-# LANGUAGE TypeFamilies #-}

module Max.Effects.Blob
  ( Blob,
    BlobRef,
    runBlob,
    putBlob,
    readBlob,
    resolveBlobHostPath,
    blobRefFromSha256,
    blobRefSha256,
    blobRefStoredPath,
  )
where

import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.Char (isDigit)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Effectful
import Effectful.Dispatch.Dynamic (interpret, send)
import Max.Util (withBinaryTempFile)
import System.Directory (createDirectoryIfMissing, doesFileExist, renameFile)
import System.FilePath (takeFileName, (</>))
import System.IO (hClose)

-- | Opaque content address for one object in the blob store.  Keeping this
-- distinct from database paths and arbitrary text prevents ordinary consumers
-- from escaping the store boundary by joining paths themselves.
newtype BlobRef = BlobRef {blobRefSha256 :: Text}
  deriving stock (Show, Eq, Ord)

data Blob :: Effect where
  PutBlob ::
    ByteString ->
    -- | Write bytes (idempotent on identical content), returning their address.
    Blob m BlobRef
  ReadBlob ::
    BlobRef ->
    -- | Read bytes without exposing the backing filesystem layout.
    Blob m ByteString
  ResolveBlobHostPath ::
    BlobRef ->
    -- | Exceptional escape hatch for APIs that require a host path, such as
    -- @docker cp@ and ffmpeg.  Ordinary consumers should use 'ReadBlob'.
    Blob m FilePath

type instance DispatchOf Blob = Dynamic

-- | Content-addressed filesystem store under @root/<2-hex-prefix>/<sha>@.
-- Concurrent writes for the same sha are safe: a unique scoped tmp filename
-- is used per call and the final 'renameFile' is an atomic POSIX move. If a
-- writer loses the race, its tmp file is renamed on top of byte-identical
-- content. Cancellation before that commit removes the temp file and closes
-- its handle.
runBlob :: (IOE :> es) => FilePath -> Eff (Blob : es) a -> Eff es a
runBlob root = interpret $ \_ -> \case
  PutBlob bs -> do
    let sha = sha256Hex bs
        rel = relPath sha
    liftIO (writeFileSafe root rel bs)
    pure (BlobRef sha)
  ReadBlob ref -> liftIO (BS.readFile (hostPath root ref))
  ResolveBlobHostPath ref -> pure (hostPath root ref)

putBlob :: (Blob :> es) => ByteString -> Eff es BlobRef
putBlob bs = send (PutBlob bs)

readBlob :: (Blob :> es) => BlobRef -> Eff es ByteString
readBlob = send . ReadBlob

resolveBlobHostPath :: (Blob :> es) => BlobRef -> Eff es FilePath
resolveBlobHostPath = send . ResolveBlobHostPath

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
blobRefStoredPath = T.pack . relPath . (.blobRefSha256)

sha256Hex :: ByteString -> Text
sha256Hex = TE.decodeUtf8 . B16.encode . SHA256.hash

relPath :: Text -> FilePath
relPath sha = T.unpack (T.take 2 sha) </> T.unpack sha

hostPath :: FilePath -> BlobRef -> FilePath
hostPath root ref = root </> relPath ref.blobRefSha256

writeFileSafe :: FilePath -> FilePath -> ByteString -> IO ()
writeFileSafe root rel bytes = do
  let final = root </> rel
  exists <- doesFileExist final
  if exists
    then pure ()
    else do
      let subdir = root </> take 2 rel
      createDirectoryIfMissing True subdir
      withBinaryTempFile subdir (takeFileName rel <> ".tmp") $ \tmp h -> do
        BS.hPut h bytes
        hClose h
        renameFile tmp final
