{-# LANGUAGE TypeFamilies #-}

-- | Host-path bridge for adapters whose external process owns the input
-- handle (docker cp and ffmpeg). Content consumers only need 'Blob'.
module Max.Effects.BlobHost
  ( BlobHost,
    runBlobHost,
    resolveBlobHostPath,
  )
where

import Data.Text qualified as T
import Effectful
import Effectful.Dispatch.Dynamic (interpret, send)
import Max.Effects.Blob (BlobRef, blobRefStoredPath)
import System.FilePath ((</>))

data BlobHost :: Effect where
  ResolveBlobHostPath :: BlobRef -> BlobHost m FilePath

type instance DispatchOf BlobHost = Dynamic

runBlobHost :: FilePath -> Eff (BlobHost : es) a -> Eff es a
runBlobHost root = interpret $ \_ -> \case
  ResolveBlobHostPath ref -> pure (root </> T.unpack (blobRefStoredPath ref))

resolveBlobHostPath :: (BlobHost :> es) => BlobRef -> Eff es FilePath
resolveBlobHostPath = send . ResolveBlobHostPath
