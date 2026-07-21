{-# LANGUAGE TypeFamilies #-}

module Max.Effects.Blob
  ( Blob,
    runBlob,
    putBlob,
    blobPath,
  )
where

import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Effectful
import Effectful.Dispatch.Dynamic (interpret, send)
import System.Directory (createDirectoryIfMissing, doesFileExist, renameFile)
import System.FilePath (takeFileName, (</>))
import System.IO qualified as IO

data Blob :: Effect where
  PutBlob :: ByteString -> Blob m Text
  -- ^ Write bytes (idempotent on identical content), return hex sha256.
  BlobPath :: Text -> Blob m FilePath
  -- ^ Resolve a sha256 to the relative path under the blob root.

type instance DispatchOf Blob = Dynamic

-- | Content-addressed filesystem store under @root/<2-hex-prefix>/<sha>@.
-- Concurrent writes for the same sha are safe: a unique tmp filename is
-- used per call ('openBinaryTempFile') and the final 'renameFile' is an
-- atomic POSIX move. If a writer loses the race, its tmp file is renamed
-- on top of byte-identical content.
runBlob :: IOE :> es => FilePath -> Eff (Blob : es) a -> Eff es a
runBlob root = interpret $ \_ -> \case
  PutBlob bs -> do
    let sha = sha256Hex bs
        rel = relPath sha
    liftIO (writeFileSafe root rel bs)
    pure sha
  BlobPath sha -> pure (relPath sha)

putBlob :: Blob :> es => ByteString -> Eff es Text
putBlob bs = send (PutBlob bs)

blobPath :: Blob :> es => Text -> Eff es FilePath
blobPath sha = send (BlobPath sha)

sha256Hex :: ByteString -> Text
sha256Hex = TE.decodeUtf8 . B16.encode . SHA256.hash

relPath :: Text -> FilePath
relPath sha = T.unpack (T.take 2 sha) </> T.unpack sha

writeFileSafe :: FilePath -> FilePath -> ByteString -> IO ()
writeFileSafe root rel bytes = do
  let final = root </> rel
  exists <- doesFileExist final
  if exists
    then pure ()
    else do
      let subdir = root </> take 2 rel
      createDirectoryIfMissing True subdir
      (tmp, h) <- IO.openBinaryTempFile subdir (takeFileName rel <> ".tmp")
      BS.hPut h bytes
      IO.hClose h
      renameFile tmp final
