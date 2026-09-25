module Max.DB.VideoRenditionSpec (Max.DB.VideoRenditionSpec.spec) where

import Data.ByteString qualified as BS
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Int (Int64)
import Data.Maybe (isJust)
import Database.PostgreSQL.Simple (Only (..))
import Effectful (liftIO)
import Effectful.PostgreSQL (query_)
import Helpers (truncateAll, withDb, withDbLog)
import Max.DB.Connection (DbPool)
import Max.Media.Rendition (videoRendition)
import Max.Media.Vision (VideoAttachment (..), VideoWindow (..), wholeVideo)
import Max.ModelCatalog (VisionLimits (..))
import System.Directory (findExecutable)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (callProcess)
import Test.Hspec

spec :: DbPool -> Spec
spec pool = before_ (truncateAll pool) $ describe "video renditions" $
  it "caches one rendition per source and window, reading the source once" $ do
    ffmpeg <- findExecutable "ffmpeg"
    case ffmpeg of
      Nothing -> pendingWith "ffmpeg is not installed"
      Just _ -> withSystemTempDirectory "rendition-spec" $ \dir -> do
        let source = dir </> "source.mp4"
            limits = VisionLimits 49152 16384 600 768 25165824
        callProcess "ffmpeg" ["-v", "error", "-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=25:duration=20", "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", source]
        bytes <- BS.readFile source
        loads <- newIORef (0 :: Int)
        let load = liftIO (modifyIORef' loads (+ 1)) >> pure (Right bytes)
            render window = withDbLog pool (videoRendition limits window "source-sha" load)
        Right first <- render wholeVideo
        Right again <- render wholeVideo
        Right clip <- render (VideoWindow 5 (Just 10))
        readIORef loads `shouldReturn` 2
        again.attachmentDataUrl `shouldBe` first.attachmentDataUrl
        first.attachmentTokens `shouldSatisfy` maybe False (<= 12288)
        clip.attachmentNote `shouldSatisfy` (/= first.attachmentNote)
        isJust clip.attachmentTokens `shouldBe` True
        withDb pool (query_ "SELECT count(*) FROM video_renditions") `shouldReturn` [Only (2 :: Int64)]
