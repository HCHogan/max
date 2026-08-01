module Max.UtilSpec (spec) where

import Control.Concurrent (forkFinally, killThread, threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (AsyncException (ThreadKilled))
import Control.Exception qualified as CE
import Data.ByteString.Char8 qualified as BS8
import Data.Either (isLeft)
import Data.Maybe (isNothing)
import Effectful (Eff, IOE, runEff)
import Effectful.Exception qualified as EE
import Max.Tasks (TaskCancelled (..))
import Max.Util
  ( trySync,
    trySyncIO,
    withBinaryTempFile,
    withTempDirectory,
  )
import System.Directory
  ( doesDirectoryExist,
    doesFileExist,
    getTemporaryDirectory,
  )
import System.FilePath ((</>))
import System.IO (hIsClosed)
import System.Timeout (timeout)
import Test.Hspec

spec :: Spec
spec = do
  describe "synchronous exception boundaries" $ do
    it "returns synchronous IO exceptions as Left" $ do
      result <- trySyncIO (CE.throwIO (userError "boom") :: IO ())
      result `shouldSatisfy` isLeft

    it "returns synchronous Effectful exceptions as Left" $ do
      result <- runEff (trySync (EE.throwIO (userError "boom") :: Eff '[IOE] ()))
      result `shouldSatisfy` isLeft

    it "lets ordinary async exceptions cross trySyncIO" $ do
      result <-
        CE.try @AsyncException $
          trySyncIO (CE.throwIO ThreadKilled :: IO ())
      result `shouldSatisfy` isLeft

    it "lets TaskCancelled cross both exception boundaries" $ do
      ioResult <-
        CE.try @TaskCancelled $
          trySyncIO (CE.throwIO TaskCancelled :: IO ())
      effResult <-
        CE.try @TaskCancelled $
          runEff (trySync (EE.throwIO TaskCancelled :: Eff '[IOE] ()))
      ioResult `shouldSatisfy` isLeft
      effResult `shouldSatisfy` isLeft

    it "does not turn a timeout cancellation into Left" $ do
      result <- timeout 20_000 (trySyncIO (threadDelay 5_000_000))
      result `shouldSatisfy` isNothing

  describe "temporary resource scopes" $ do
    it "closes and removes a temp file when its user is cancelled" $ do
      tmp <- getTemporaryDirectory
      ready <- newEmptyMVar
      blocked <- newEmptyMVar
      done <- newEmptyMVar
      tid <-
        forkFinally
          ( withBinaryTempFile tmp "max-util-test-" $ \path handle -> do
              putMVar ready (path, handle)
              takeMVar blocked
          )
          (putMVar done)
      (path, handle) <- takeMVar ready
      doesFileExist path `shouldReturn` True
      killThread tid
      _ <- takeMVar done
      hIsClosed handle `shouldReturn` True
      doesFileExist path `shouldReturn` False

    it "removes a complete temp workspace when its user is cancelled" $ do
      ready <- newEmptyMVar
      blocked <- newEmptyMVar
      done <- newEmptyMVar
      tid <-
        forkFinally
          ( withTempDirectory "max-util-workspace-" $ \workspace -> do
              BS8.writeFile (workspace </> "derived-output") "partial"
              putMVar ready workspace
              takeMVar blocked
          )
          (putMVar done)
      workspace <- takeMVar ready
      doesDirectoryExist workspace `shouldReturn` True
      killThread tid
      _ <- takeMVar done
      doesDirectoryExist workspace `shouldReturn` False
