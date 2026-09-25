module Max.Search.RuntimeSpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (concurrently)
import Data.Aeson (Value (..), encode, object, (.=))
import Data.Aeson.Types (parseEither)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as B8
import Data.ByteString.Lazy qualified as LBS
import Data.Either (isLeft)
import Data.IORef (atomicModifyIORef', modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Data.Time (UTCTime (..), addUTCTime, fromGregorian)
import Effectful (runEff)
import Effectful.Log (runLog)
import Log (LogLevel (LogAttention))
import Max.Http.Failure (ResponseFailure (..), TransportFailure (..))
import Max.HttpRuntime (HttpRuntime, httpRuntimeFromManagers)
import Max.Log (ColorMode (ColorNever), withCompactLogger)
import Max.Search.Runtime
import Max.Tools.Search.Types (SearchConfig (..))
import Network.HTTP.Client (ManagerSettings (..), defaultManagerSettings, makeConnection, managerSetProxy, newManager, noProxy)
import Test.Hspec

spec :: Spec
spec = describe "Exa search" $ do
  it "decodes hosted MCP SSE and preserves the batch-search result contract" $ do
    decodeMcpResponse 5 ("event: message\r\ndata: " <> mcpBody <> "\r\n\r\n") `shouldBe` Right expected
    decodeMcpResponse 5 mcpBody `shouldBe` Right expected
  it "accepts notifications before a multiline SSE response" $ do
    let body = "data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\"}\n\nevent: message\ndata: {\"id\":1,\ndata: \"result\":{\"content\":[{\"type\":\"text\",\"text\":\"No search results found. Please try a different query.\"}]}}\n\n"
    decodeMcpResponse 5 body `shouldBe` Right (object ["answer" .= Null, "results" .= ([] :: [Value])])
  it "rejects RPC errors, tool errors, malformed data and mismatched request ids" $ do
    mapM_
      (\body -> decodeMcpResponse 5 body `shouldSatisfy` isLeft)
      [ "{\"id\":null,\"error\":{\"code\":-32000,\"message\":\"limited\"}}",
        "{\"id\":1,\"result\":{\"isError\":true,\"content\":[]}}",
        "{\"id\":1,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"unexpected format\"}]}}",
        "{\"id\":2,\"result\":{\"content\":[]}}",
        "event: message\ndata: broken\n\n"
      ]
  it "normalizes API highlights and respects the requested result limit" $ do
    parseEither (compactApiResponse 1) apiValue `shouldBe` Right expected
    let structured = LBS.toStrict (encode (object ["id" .= (1 :: Int), "result" .= object ["structuredContent" .= apiValue]]))
    decodeMcpResponse 1 structured `shouldBe` Right expected
  it "preserves separators within source text and splits actual result boundaries" $ do
    let row = "Title: Haskell\nURL: https://haskell.org/\nPublished: N/A\nAuthor: N/A\nHighlights:\nA language"
        body = LBS.toStrict (encode (mcpResult (row <> "\n\n---\n\nMore context\n\n---\n\n" <> row)))
        firstRow = object ["title" .= ("Haskell" :: Text), "url" .= ("https://haskell.org/" :: Text), "snippet" .= ("A language\n\n---\n\nMore context" :: Text)]
    decodeMcpResponse 1 body `shouldBe` Right (object ["answer" .= Null, "results" .= [firstRow]])
  it "retries transient failures twice with bounded backoff" $ do
    replies <- newIORef [Left (ResponseTransport ConnectionTimeoutFailure), Left (ResponseTransport (HttpStatusFailure 503 [] "busy" False)), Right expected]
    pauses <- newIORef []
    let attempt = atomicModifyIORef' replies $ \case
          value : rest -> (rest, value)
          [] -> error "unexpected retry"
    retrySearch (\delay -> modifyIORef' pauses (<> [delay])) attempt `shouldReturn` Right expected
    readIORef pauses `shouldReturn` [1000000, 3000000]
  it "stops retrying after three attempts and does not retry permanent errors or 429" $ do
    calls <- newIORef (0 :: Int)
    let failure = ResponseTransport ResponseTimeoutFailure
    retrySearch (const (pure ())) (modifyIORef' calls (+ 1) >> pure (Left failure :: Either ResponseFailure Value)) `shouldReturn` Left failure
    readIORef calls `shouldReturn` 3
    mapM_
      ( \code -> do
          let rejected = ResponseTransport (HttpStatusFailure code [] "rejected" False)
          retrySearch (\_ -> expectationFailure "must not retry") (pure (Left rejected :: Either ResponseFailure Value)) `shouldReturn` Left rejected
      )
      [400, 401, 402, 403, 429]
  it "honors Retry-After seconds and dates with a conservative fallback" $ do
    let now = UTCTime (fromGregorian 2026 9 25) 0
        limited value = ResponseTransport (HttpStatusFailure 429 [("Retry-After", value)] "limited" False)
    cooldownUntil now (limited "86400") `shouldBe` addUTCTime 86400 now
    cooldownUntil now (limited "Fri, 25 Sep 2026 00:02:00 GMT") `shouldBe` addUTCTime 120 now
    cooldownUntil now (limited "bad") `shouldBe` addUTCTime 60 now
    cooldownUntil now (limited "0") `shouldBe` addUTCTime 1 now
  it "uses free MCP without sending the fallback credential" $ do
    (http, requests) <- fixture [wire "200 OK" [] mcpBody]
    search <- newSearchRuntime (SearchConfig (Just "test-secret") 5 30)
    runQuery http search `shouldReturn` Right expected
    sent <- requests
    length sent `shouldBe` 1
    map fst sent `shouldBe` ["mcp.exa.ai"]
    BS.concat (map snd sent) `shouldSatisfy` (not . B8.isInfixOf "test-secret")
    BS.concat (map snd sent) `shouldSatisfy` B8.isInfixOf "web_search_exa"
  it "falls back once on 429 and shares the cooldown between concurrent callers" $ do
    (http, requests) <- fixture [wire "429 Too Many Requests" [("Retry-After", "86400")] "limited", wire "200 OK" [] (LBS.toStrict (encode apiValue)), wire "200 OK" [] (LBS.toStrict (encode apiValue))]
    search <- newSearchRuntime (SearchConfig (Just "test-secret") 1 30)
    concurrently (runQuery http search) (runQuery http search) `shouldReturn` (Right expected, Right expected)
    sent <- requests
    map fst sent `shouldBe` ["mcp.exa.ai", "api.exa.ai", "api.exa.ai"]
    map snd (drop 1 sent) `shouldSatisfy` all (B8.isInfixOf "x-api-key: test-secret")
  it "reports exhaustion without a key and does not keep hitting free MCP" $ do
    (http, requests) <- fixture [wire "429 Too Many Requests" [("Retry-After", "86400")] "limited"]
    search <- newSearchRuntime (SearchConfig Nothing 5 30)
    runQuery http search `shouldReturnSatisfy` isLeft
    runQuery http search `shouldReturnSatisfy` isLeft
    length <$> requests `shouldReturn` 1
  it "does not spend API credits for a successful empty result" $ do
    let empty = LBS.toStrict (encode (mcpResult "No search results found. Please try a different query."))
    (http, requests) <- fixture [wire "200 OK" [] empty]
    search <- newSearchRuntime (SearchConfig (Just "test-secret") 5 30)
    runQuery http search `shouldReturn` Right (object ["answer" .= Null, "results" .= ([] :: [Value])])
    length <$> requests `shouldReturn` 1
  it "falls back on malformed MCP content but does not retry an invalid API key" $ do
    (http, requests) <- fixture [wire "200 OK" [] "broken", wire "401 Unauthorized" [] "invalid key"]
    search <- newSearchRuntime (SearchConfig (Just "test-secret") 5 30)
    runQuery http search `shouldReturnSatisfy` isLeft
    runQuery http search `shouldReturnSatisfy` isLeft
    length <$> requests `shouldReturn` 2
  it "retries a transient MCP HTTP failure before spending API credits" $ do
    (http, requests) <- fixture [wire "503 Unavailable" [] "busy", wire "200 OK" [] mcpBody]
    search <- newSearchRuntime (SearchConfig (Just "test-secret") 5 30)
    runQuery http search `shouldReturn` Right expected
    map fst <$> requests `shouldReturn` ["mcp.exa.ai", "mcp.exa.ai"]
  it "does not retry or fall back on invalid queries, or cool down unrelated queries" $ do
    (http, requests) <- fixture [wire "400 Bad Request" [] "bad query", wire "200 OK" [] mcpBody]
    search <- newSearchRuntime (SearchConfig (Just "test-secret") 5 30)
    runQuery http search `shouldReturnSatisfy` isLeft
    runQuery http search `shouldReturn` Right expected
    map fst <$> requests `shouldReturn` ["mcp.exa.ai", "mcp.exa.ai"]
  it "tries free MCP again after its cooldown expires" $ do
    (http, requests) <- fixture [wire "429 Too Many Requests" [("Retry-After", "1")] "limited", wire "200 OK" [] mcpBody]
    search <- newSearchRuntime (SearchConfig Nothing 5 30)
    runQuery http search `shouldReturnSatisfy` isLeft
    threadDelay 1100000
    runQuery http search `shouldReturn` Right expected
    length <$> requests `shouldReturn` 2

runQuery :: HttpRuntime -> SearchRuntime -> IO (Either Text Value)
runQuery http search = withCompactLogger ColorNever Nothing $ \logger ->
  runEff . runLog "search-test" logger LogAttention $ searchExa http search "Haskell" 1

shouldReturnSatisfy :: (Show value) => IO value -> (value -> Bool) -> Expectation
shouldReturnSatisfy action predicate = action >>= (`shouldSatisfy` predicate)

mcpResult :: Text -> Value
mcpResult text = object ["jsonrpc" .= ("2.0" :: Text), "id" .= (1 :: Int), "result" .= object ["content" .= [object ["type" .= ("text" :: Text), "text" .= text]]]]

mcpBody :: ByteString
mcpBody = LBS.toStrict (encode (mcpResult "Title: Haskell\nURL: https://haskell.org/\nPublished: N/A\nAuthor: N/A\nHighlights:\nA language"))

apiValue :: Value
apiValue = object ["results" .= replicate 2 (object ["title" .= ("Haskell" :: Text), "url" .= ("https://haskell.org/" :: Text), "highlights" .= (["A language"] :: [Text])])]

expected :: Value
expected = object ["answer" .= Null, "results" .= [object ["title" .= ("Haskell" :: Text), "url" .= ("https://haskell.org/" :: Text), "snippet" .= ("A language" :: Text)]]]

fixture :: [ByteString] -> IO (HttpRuntime, IO [(String, ByteString)])
fixture responses = do
  remaining <- newIORef responses
  requests <- newIORef []
  let connect _ host _ = do
        bytes <- atomicModifyIORef' remaining $ \case
          value : rest -> (rest, value)
          [] -> error "unexpected HTTP attempt"
        chunks <- newIORef [bytes]
        written <- newIORef BS.empty
        makeConnection
          (atomicModifyIORef' chunks $ \case [] -> ([], BS.empty); value : rest -> (rest, value))
          (\chunk -> modifyIORef' written (<> chunk))
          (readIORef written >>= \body -> atomicModifyIORef' requests (\current -> (current <> [(host, body)], ())))
  manager <-
    newManager
      (managerSetProxy noProxy defaultManagerSettings)
        { managerTlsConnection = pure connect,
          managerRetryableException = const False
        }
  pure (httpRuntimeFromManagers manager manager manager, readIORef requests)

wire :: ByteString -> [(ByteString, ByteString)] -> ByteString -> ByteString
wire status headers body = "HTTP/1.1 " <> status <> "\r\nContent-Length: " <> B8.pack (show (BS.length body)) <> "\r\nConnection: close\r\n" <> BS.concat [name <> ": " <> value <> "\r\n" | (name, value) <- headers] <> "\r\n" <> body
