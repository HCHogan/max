module Max.Effects.BlobSpec (spec) where

import Data.ByteString.Char8 qualified as BS8
import Data.Maybe (isJust)
import Data.Text qualified as T
import Effectful (runEff)
import Max.Effects.Blob
  ( blobRefFromSha256,
    blobRefSha256,
    blobRefStoredPath,
    putBlob,
    readBlob,
    runBlob,
  )
import Max.Effects.BlobHost (resolveBlobHostPath, runBlobHost)
import Max.Util (withTempDirectory)
import System.Directory (doesFileExist)
import System.FilePath ((</>))
import Test.Hspec

spec :: Spec
spec = describe "Blob" $ do
  it "round-trips bytes through an opaque content reference" $
    withTempDirectory "max-blob-test" $ \root -> do
      let payload = BS8.pack "blob boundary"
      (ref, bytes, host) <-
        runEff . runBlobHost root . runBlob root $ do
          ref <- putBlob payload
          bytes <- readBlob ref
          host <- resolveBlobHostPath ref
          pure (ref, bytes, host)
      let sha = blobRefSha256 ref
      bytes `shouldBe` payload
      T.length sha `shouldBe` 64
      blobRefStoredPath ref `shouldBe` T.pack (T.unpack (T.take 2 sha) </> T.unpack sha)
      host `shouldBe` root </> T.unpack (blobRefStoredPath ref)
      doesFileExist host `shouldReturn` True

  it "rejects malformed or path-shaped durable references" $ do
    blobRefFromSha256 (T.replicate 63 "a") `shouldBe` Nothing
    blobRefFromSha256 (T.replicate 64 "A") `shouldBe` Nothing
    blobRefFromSha256 "../../outside" `shouldBe` Nothing
    blobRefFromSha256 (T.replicate 64 "f") `shouldSatisfy` isJust
