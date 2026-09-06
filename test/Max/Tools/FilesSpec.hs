module Max.Tools.FilesSpec (spec) where

import Data.ByteString qualified as BS
import Max.Sandbox.Docker (readBoundedArtifact)
import Max.Util (withTempDirectory)
import System.FilePath ((</>))
import System.IO (IOMode (ReadMode), withBinaryFile)
import Test.Hspec

spec :: Spec
spec = describe "artifact read boundary" $ do
  it "accepts an exact fit and rejects a larger file before retaining it" $
    withTempDirectory "artifact-bound" $ \root -> do
      let path = root </> "artifact"
      BS.writeFile path "12345"
      withBinaryFile path ReadMode (readBoundedArtifact 5) `shouldReturn` Right "12345"
      withBinaryFile path ReadMode (readBoundedArtifact 4) `shouldReturn` Left "sandbox artifact exceeds byte limit"
