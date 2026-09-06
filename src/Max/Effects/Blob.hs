{-# LANGUAGE TypeFamilies #-}

module Max.Effects.Blob
  ( Blob,
    BlobRef,
    runBlob,
    putBlob,
    readBlob,
    blobRefFromSha256,
    blobRefSha256,
    blobRefStoredPath,
  )
where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Text qualified as T
import Effectful
import Effectful.Dispatch.Dynamic (interpret, send)
import Max.Blob.Reference
import Max.Util (withBinaryTempFile)
import System.Directory (createDirectoryIfMissing, doesFileExist, renameFile)
import System.FilePath (takeFileName, (</>))
import System.IO (hClose)

data Blob :: Effect where
  PutBlob ::
    ByteString ->
    -- | Write bytes (idempotent on identical content), returning their address.
    Blob m BlobRef
  ReadBlob ::
    BlobRef ->
    -- | Read bytes without exposing the backing filesystem layout.
    Blob m ByteString

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
    let ref = blobRefForBytes bs
        rel = T.unpack (blobRefStoredPath ref)
    liftIO (writeFileSafe root rel bs)
    pure ref
  ReadBlob ref -> liftIO (BS.readFile (hostPath root ref))

putBlob :: (Blob :> es) => ByteString -> Eff es BlobRef
putBlob bs = send (PutBlob bs)

readBlob :: (Blob :> es) => BlobRef -> Eff es ByteString
readBlob = send . ReadBlob

hostPath :: FilePath -> BlobRef -> FilePath
hostPath root ref = root </> T.unpack (blobRefStoredPath ref)

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
