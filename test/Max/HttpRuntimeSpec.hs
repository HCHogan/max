module Max.HttpRuntimeSpec (spec) where

import Control.Concurrent (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.Async (AsyncCancelled, async, cancel, waitCatch)
import Control.Exception (fromException, toException)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef, readIORef)
import Max.HttpRuntime
import Network.HTTP.Client
  ( HttpException (..),
    HttpExceptionContent (..),
    Manager,
    ManagerSettings (..),
    defaultManagerSettings,
    defaultRequest,
    makeConnection,
    newManager,
  )
import System.Mem.StableName (eqStableName, makeStableName)
import Test.Hspec

spec :: Spec
spec = do
  describe "HttpRuntime" $ do
    it "returns the same shared manager for repeated pool lookups" $ do
      standard <- newManager defaultManagerSettings
      qq <- newManager defaultManagerSettings
      let runtime = httpRuntimeFromManagers standard qq
      first <- makeStableName (managerFor StandardPool runtime)
      second <- makeStableName (managerFor StandardPool runtime)
      first `eqStableName` second `shouldBe` True

    it "classifies response and connection timeouts separately" $ do
      classifyTransportException
        (toException (HttpExceptionRequest defaultRequest ResponseTimeout))
        `shouldBe` ResponseTimeoutFailure
      classifyTransportException
        (toException (HttpExceptionRequest defaultRequest ConnectionTimeout))
        `shouldBe` ConnectionTimeoutFailure

    it "classifies malformed URLs as request-construction failures" $ do
      result <- parseRequestEither "http://[not-an-ipv6-address"
      case result of
        Left (RequestConstructionFailure _) -> pure ()
        Left failure -> expectationFailure ("wrong failure: " <> show failure)
        Right _ -> expectationFailure "malformed URL was accepted"

  describe "bounded bodies" $ do
    it "accepts a body exactly equal to the limit" $ do
      reader <- chunkReader ["ab", "cde"]
      readBodyBounded 5 reader `shouldReturn` Right "abcde"

    it "rejects a body that exceeds the limit" $ do
      reader <- chunkReader ["abc", "def"]
      readBodyBounded 5 reader `shouldReturn` Left (ResponseBodyLimitExceeded 5)

    it "bounds non-success response previews" $ do
      closes <- newIORef 0
      manager <- fakeManager (rawResponse 503 "0123456789") closes
      request <- expectRight =<< parseRequestEither "http://example.test/"
      let runtime = httpRuntimeFromManagers manager manager
      result <- runBuffered runtime StandardPool 100 4 request
      result
        `shouldBe` Left
          (HttpStatusFailure 503 "0123" True)

  describe "streaming response lifetime" $ do
    it "closes an unread body when the callback returns" $ do
      closes <- newIORef 0
      manager <- fakeManager (rawResponse 200 "body") closes
      request <- expectRight =<< parseRequestEither "http://example.test/"
      let runtime = httpRuntimeFromManagers manager manager
      withStreamingResponse runtime StandardPool 128 request (\_ _ -> pure ())
        `shouldReturn` Right ()
      readIORef closes `shouldReturn` 1

    it "propagates cancellation and still closes the response body" $ do
      closes <- newIORef 0
      entered <- newEmptyMVar
      blocked <- newEmptyMVar @()
      manager <- fakeManager (rawResponse 200 "body") closes
      request <- expectRight =<< parseRequestEither "http://example.test/"
      let runtime = httpRuntimeFromManagers manager manager
      worker <- async $ withStreamingResponse runtime StandardPool 128 request $ \_ _ -> do
        putMVar entered ()
        takeMVar blocked
      takeMVar entered
      cancel worker
      result <- waitCatch worker
      case result of
        Left exception ->
          (fromException exception :: Maybe AsyncCancelled) `shouldSatisfy` maybe False (const True)
        Right value -> expectationFailure ("cancellation became a value: " <> show value)
      readIORef closes `shouldReturn` 1

chunkReader :: [ByteString] -> IO (IO ByteString)
chunkReader chunks = do
  remaining <- newIORef chunks
  pure $ atomicModifyIORef' remaining $ \case
    [] -> ([], BS.empty)
    chunk : rest -> (rest, chunk)

fakeManager :: ByteString -> IORef Int -> IO Manager
fakeManager responseBytes closes =
  newManager
    defaultManagerSettings
      { managerRawConnection = pure $ \_ _ _ -> do
          responseChunks <- newIORef [responseBytes]
          makeConnection
            (atomicModifyIORef' responseChunks $ \case [] -> ([], BS.empty); chunk : rest -> (rest, chunk))
            (const (pure ()))
            (modifyIORef' closes (+ 1)),
        managerRetryableException = const False
      }

rawResponse :: Int -> ByteString -> ByteString
rawResponse code responseBody =
  "HTTP/1.1 "
    <> (if code == 200 then "200 OK" else "503 Service Unavailable")
    <> "\r\nContent-Length: "
    <> BS.pack (map (fromIntegral . fromEnum) (show (BS.length responseBody)))
    <> "\r\nConnection: close\r\n\r\n"
    <> responseBody

expectRight :: (Show e) => Either e a -> IO a
expectRight = \case
  Right value -> pure value
  Left err -> expectationFailure ("expected Right, got Left " <> show err) >> fail "unreachable"
