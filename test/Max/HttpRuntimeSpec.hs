module Max.HttpRuntimeSpec (spec) where

import Control.Concurrent (newEmptyMVar, putMVar, readMVar, takeMVar, tryPutMVar)
import Control.Concurrent.Async (AsyncCancelled, async, cancel, waitCatch)
import Control.Exception (fromException, toException)
import Control.Monad (void)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef, readIORef)
import Data.Maybe (isJust)
import Effectful (liftIO, runEff)
import Effectful.Log (runLog)
import Log (LogLevel (LogAttention))
import Max.Http.Stream (StreamOutcome (..), streamPost)
import Max.HttpRuntime
import Max.LLM.Stream (StreamAcc (..), stepOpenAI)
import Max.Log (ColorMode (ColorNever), withCompactLogger)
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
import Network.TLS qualified as TLS
import System.Timeout qualified as Timeout
import Test.Hspec

spec :: Spec
spec = do
  describe "HttpRuntime" $ do
    it "reuses a pool connection across requests" $ do
      opens <- newIORef 0
      manager <- reusableManager [rawKeepAliveResponse "one", rawKeepAliveResponse "two"] opens
      request <- expectRight =<< parseRequestEither "http://example.test/"
      let runtime = httpRuntimeFromManagers manager manager manager
      first <- runBuffered runtime StandardPool 16 16 request
      second <- runBuffered runtime StandardPool 16 16 request
      fmap (.body) first `shouldBe` Right "one"
      fmap (.body) second `shouldBe` Right "two"
      readIORef opens `shouldReturn` 1

    it "classifies response and connection timeouts separately" $ do
      classifyTransportException
        (toException (HttpExceptionRequest defaultRequest ResponseTimeout))
        `shouldBe` ResponseTimeoutFailure
      classifyTransportException
        (toException (HttpExceptionRequest defaultRequest ConnectionTimeout))
        `shouldBe` ConnectionTimeoutFailure

    it "keeps TLS failures distinct from ordinary connection failures" $ do
      classifyTransportException (toException TLS.ConnectionNotEstablished)
        `shouldSatisfy` \case
          TlsFailed _ -> True
          _ -> False

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
      let runtime = httpRuntimeFromManagers manager manager manager
      result <- runBuffered runtime StandardPool 100 4 request
      case result of
        Left (HttpStatusFailure 503 _ "0123" True) -> pure ()
        _ -> expectationFailure ("unexpected result: " <> show result)

  describe "streaming response lifetime" $ do
    it "closes an unread body when the callback returns" $ do
      closes <- newIORef 0
      manager <- fakeManager (rawResponse 200 "body") closes
      request <- expectRight =<< parseRequestEither "http://example.test/"
      let runtime = httpRuntimeFromManagers manager manager manager
      withStreamingResponse runtime StandardPool 128 request (\_ _ -> pure ())
        `shouldReturn` Right ()
      readIORef closes `shouldReturn` 1

    it "propagates cancellation and still closes the response body" $ do
      closes <- newIORef 0
      entered <- newEmptyMVar
      blocked <- newEmptyMVar @()
      manager <- fakeManager (rawResponse 200 "body") closes
      request <- expectRight =<< parseRequestEither "http://example.test/"
      let runtime = httpRuntimeFromManagers manager manager manager
      worker <- async $ withStreamingResponse runtime StandardPool 128 request $ \_ _ -> do
        putMVar entered ()
        takeMVar blocked
      takeMVar entered
      cancel worker
      result <- waitCatch worker
      case result of
        Left exception ->
          (fromException exception :: Maybe AsyncCancelled) `shouldSatisfy` isJust
        Right value -> expectationFailure ("cancellation became a value: " <> show value)
      readIORef closes `shouldReturn` 1

  describe "stream publication" $ do
    it "finishes publication acknowledgement even when the network times out after commit" $ do
      closed <- newEmptyMVar
      committed <- newIORef []
      acknowledged <- newIORef False
      manager <- stalledStreamManager [textFrame] (void $ tryPutMVar closed ())
      let runtime = httpRuntimeFromManagers manager manager manager
      result <- Timeout.timeout 3_000_000 $ withCompactLogger ColorNever Nothing $ \logger ->
        runEff $ runLog "test" logger LogAttention $ streamPost runtime [] 1 [] "http://example.test/" "{}" stepOpenAI $ \acc -> liftIO $ do
          modifyIORef' committed (<> [acc.saText])
          -- Hold publication after the externally visible commit until the
          -- network timeout closes its socket. Its acknowledgement must survive.
          readMVar closed
          modifyIORef' acknowledged (const True)
      case result of
        Just (StreamTruncated acc "stream timed out") -> acc.saText `shouldBe` "first paragraph"
        _ -> expectationFailure ("unexpected result: " <> show result)
      readIORef committed `shouldReturn` ["first paragraph"]
      readIORef acknowledged `shouldReturn` True

    it "propagates publication failures and closes the network reader" $ do
      closed <- newEmptyMVar
      manager <- stalledStreamManager [textFrame] (void $ tryPutMVar closed ())
      let runtime = httpRuntimeFromManagers manager manager manager
      withCompactLogger
        ColorNever
        Nothing
        ( \logger ->
            runEff $ runLog "test" logger LogAttention $ streamPost runtime [] 30 [] "http://example.test/" "{}" stepOpenAI $ \_ ->
              liftIO $ ioError (userError "publication failed")
        )
        `shouldThrow` anyIOException
      Timeout.timeout 1_000_000 (readMVar closed) `shouldReturn` Just ()

    it "honours caller cancellation during publication without returning a retryable result" $ do
      entered <- newEmptyMVar
      blocked <- newEmptyMVar @()
      closed <- newEmptyMVar
      manager <- stalledStreamManager [textFrame] (void $ tryPutMVar closed ())
      let runtime = httpRuntimeFromManagers manager manager manager
      withCompactLogger ColorNever Nothing $ \logger -> do
        worker <- async $
          runEff $
            runLog "test" logger LogAttention $
              streamPost runtime [] 30 [] "http://example.test/" "{}" stepOpenAI $ \_ -> liftIO $ do
                putMVar entered ()
                takeMVar blocked
        Timeout.timeout 1_000_000 (takeMVar entered) `shouldReturn` Just ()
        cancel worker
        result <- waitCatch worker
        case result of
          Left exception -> (fromException exception :: Maybe AsyncCancelled) `shouldSatisfy` isJust
          Right value -> expectationFailure ("cancellation became a value: " <> show value)
      Timeout.timeout 1_000_000 (readMVar closed) `shouldReturn` Just ()

    it "retains trailing usage and completes when the socket times out after a terminal frame" $ do
      closed <- newEmptyMVar
      manager <-
        stalledStreamManager
          [ textFrame,
            "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n",
            "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":3}}\n\n",
            "data: [DONE]\n\n"
          ]
          (void $ tryPutMVar closed ())
      let runtime = httpRuntimeFromManagers manager manager manager
      result <- Timeout.timeout 3_000_000 $ withCompactLogger ColorNever Nothing $ \logger ->
        runEff $ runLog "test" logger LogAttention $ streamPost runtime [] 1 [] "http://example.test/" "{}" stepOpenAI (const (pure ()))
      case result of
        Just (StreamComplete acc) -> do
          acc.saText `shouldBe` "first paragraph"
          acc.saPromptTokens `shouldBe` Just 10
          acc.saCompletionTokens `shouldBe` Just 3
        _ -> expectationFailure ("unexpected result: " <> show result)
      Timeout.timeout 1_000_000 (readMVar closed) `shouldReturn` Just ()

chunkReader :: [ByteString] -> IO (IO ByteString)
chunkReader chunks = do
  remaining <- newIORef chunks
  pure $ atomicModifyIORef' remaining $ \case
    [] -> ([], BS.empty)
    chunk : rest -> (rest, chunk)

textFrame :: ByteString
textFrame = "data: {\"choices\":[{\"delta\":{\"content\":\"first paragraph\"}}]}\n\n"

-- A provider that emits SSE and then holds an incomplete response open.
stalledStreamManager :: [ByteString] -> IO () -> IO Manager
stalledStreamManager frames close = do
  blocked <- newEmptyMVar
  newManager
    defaultManagerSettings
      { managerRawConnection = pure $ \_ _ _ -> do
          chunks <- newIORef ("HTTP/1.1 200 OK\r\nContent-Length: 1000000\r\n\r\n" : frames)
          makeConnection
            (atomicModifyIORef' chunks (\case [] -> ([], Nothing); chunk : rest -> (rest, Just chunk)) >>= maybe (takeMVar blocked) pure)
            (const (pure ()))
            close,
        managerRetryableException = const False
      }

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

reusableManager :: [ByteString] -> IORef Int -> IO Manager
reusableManager responses opens =
  newManager
    defaultManagerSettings
      { managerRawConnection = pure $ \_ _ _ -> do
          modifyIORef' opens (+ 1)
          responseChunks <- newIORef responses
          makeConnection
            (atomicModifyIORef' responseChunks $ \case [] -> ([], BS.empty); chunk : rest -> (rest, chunk))
            (const (pure ()))
            (pure ()),
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

rawKeepAliveResponse :: ByteString -> ByteString
rawKeepAliveResponse responseBody =
  "HTTP/1.1 200 OK\r\nContent-Length: "
    <> BS.pack (map (fromIntegral . fromEnum) (show (BS.length responseBody)))
    <> "\r\n\r\n"
    <> responseBody

expectRight :: (Show e) => Either e a -> IO a
expectRight = \case
  Right value -> pure value
  Left err -> expectationFailure ("expected Right, got Left " <> show err) >> fail "unreachable"
