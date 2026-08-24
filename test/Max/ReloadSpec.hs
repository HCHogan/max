module Max.ReloadSpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, cancel, mapConcurrently)
import Control.Exception (bracket)
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Effectful (liftIO, runEff)
import Max.Reload
import Max.Reload.Prepare (preflightChangedListener)
import Network.Socket qualified as Socket
import System.Directory (createDirectory, doesPathExist, getTemporaryDirectory, removeDirectoryRecursive, removeFile)
import System.IO (hClose, openTempFile)
import Test.Hspec

spec :: Spec
spec = describe "reload control protocol" $ do
  it "waits for and returns the running process's real outcome" $
    withSocketPath $ \path -> do
      calls <- newIORef (0 :: Int)
      let response = ReloadResponse True 7 8 ["persona"] [] Nothing
          perform = do
            liftIO (threadDelay 30_000)
            liftIO (atomicModifyIORef' calls (\n -> (n + 1, ())))
            pure response
      server <- async (runEff (runReloadServer path perform))
      waitForPath path
      requestReload path `shouldReturn` Right response
      readIORef calls `shouldReturn` 1
      cancel server

  it "serializes concurrent requests" $
    withSocketPath $ \path -> do
      inFlight <- newIORef (0 :: Int)
      maximumSeen <- newIORef (0 :: Int)
      let perform = do
            liftIO $ atomicModifyIORef' inFlight (\n -> let next = n + 1 in (next, ()))
            now <- liftIO (readIORef inFlight)
            liftIO $ atomicModifyIORef' maximumSeen (\n -> (max n now, ()))
            liftIO (threadDelay 20_000)
            liftIO $ atomicModifyIORef' inFlight (\n -> (n - 1, ()))
            pure (ReloadResponse True 1 1 [] [] Nothing)
      server <- async (runEff (runReloadServer path perform))
      waitForPath path
      results <- mapConcurrently (const (requestReload path)) [1 .. 5 :: Int]
      results `shouldSatisfy` all (== Right (ReloadResponse True 1 1 [] [] Nothing))
      readIORef maximumSeen `shouldReturn` 1
      cancel server

  it "rejects a changed listener address that is already occupied"
    $ Socket.withSocketsDo
    $ bracket
      (Socket.socket Socket.AF_INET Socket.Stream Socket.defaultProtocol)
      Socket.close
    $ \listener -> do
      Socket.setSocketOption listener Socket.ReuseAddr 1
      Socket.bind listener (Socket.SockAddrInet 0 (Socket.tupleToHostAddress (127, 0, 0, 1)))
      Socket.listen listener 1
      Socket.SockAddrInet port _ <- Socket.getSocketName listener
      preflightChangedListener Nothing (Just ("127.0.0.1", fromIntegral port))
        `shouldThrow` anyIOException

  it "accepts an unchanged listener address because the old generation owns it" $
    preflightChangedListener (Just ("127.0.0.1", 1)) (Just ("127.0.0.1", 1))

withSocketPath :: (FilePath -> IO a) -> IO a
withSocketPath action = bracket make removeDirectoryRecursive (action . (<> "/control.sock"))
  where
    make = do
      parent <- getTemporaryDirectory
      (marker, handle) <- openTempFile parent "max-reload-test"
      hClose handle
      removeFile marker
      createDirectory marker
      pure marker

waitForPath :: FilePath -> IO ()
waitForPath path = go (200 :: Int)
  where
    go 0 = expectationFailure "reload socket was not created"
    go n = do
      exists <- doesPathExist path
      if exists then pure () else threadDelay 1_000 >> go (n - 1)
