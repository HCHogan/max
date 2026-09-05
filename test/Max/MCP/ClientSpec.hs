module Max.MCP.ClientSpec (spec) where

import Data.Aeson (Value, object, (.=))
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy.Char8 qualified as LBS8
import Data.IORef (atomicModifyIORef', modifyIORef', newIORef, readIORef)
import Max.HttpRuntime (httpRuntimeFromManagers)
import Max.MCP.Client
  ( McpErrorKind (..),
    classifyHttpError,
    decodeRpcBody,
    mcpCallTool,
    mcpErrorKind,
    mcpErrorMetadata,
    mcpInitialize,
    mcpTerminate,
    mcpTextContent,
    newMcpClient,
    toolResultError,
  )
import Network.HTTP.Client (ManagerSettings (..), defaultManagerSettings, makeConnection, newManager)
import Test.Hspec

-- The JSON-RPC envelope both success cases should decode to.
envelope :: Value
envelope =
  object
    [ "jsonrpc" .= ("2.0" :: String),
      "id" .= (1 :: Int),
      "result" .= object ["ok" .= True]
    ]

spec :: Spec
spec = do
  describe "non-reusing MCP transport" $ do
    it "uses fresh connections for initialization, calls and termination without losing the session" $ do
      opens <- newIORef (0 :: Int)
      writes <- newIORef []
      forbidden <- newManager defaultManagerSettings {managerRawConnection = pure $ \_ _ _ -> fail "MCP used a shared pool"}
      manager <-
        newManager
          defaultManagerSettings
            { managerIdleConnectionCount = 0,
              managerRetryableException = const False,
              managerRawConnection = pure $ \_ _ _ -> do
                modifyIORef' opens (+ 1)
                chunks <- newIORef [rpcResponse]
                makeConnection
                  (atomicModifyIORef' chunks $ \case [] -> ([], BS8.empty); chunk : rest -> (rest, chunk))
                  (\bytes -> modifyIORef' writes (<> [bytes]))
                  (pure ())
            }
      let runtime = httpRuntimeFromManagers forbidden forbidden manager
      client <- newMcpClient runtime "http://example.test/mcp" "localhost:8931"
      mcpInitialize client `shouldReturn` Right ()
      mcpCallTool client "fixture" (object []) `shouldReturn` Right (object ["ok" .= True])
      mcpCallTool client "fixture" (object []) `shouldReturn` Right (object ["ok" .= True])
      mcpTerminate client
      readIORef opens `shouldReturn` 5
      requests <- BS8.concat <$> readIORef writes
      requests `shouldSatisfy` BS8.isInfixOf "Mcp-Session-Id: fixture-session"
      requests `shouldSatisfy` BS8.isInfixOf "DELETE /mcp"

    it "never replays a tool call when its response is lost" $ do
      opens <- newIORef (0 :: Int)
      manager <-
        newManager
          defaultManagerSettings
            { managerIdleConnectionCount = 0,
              managerRetryableException = const False,
              managerRawConnection = pure $ \_ _ _ -> do
                modifyIORef' opens (+ 1)
                makeConnection (pure BS8.empty) (const (pure ())) (pure ())
            }
      client <- newMcpClient (httpRuntimeFromManagers manager manager manager) "http://example.test/mcp" "localhost:8931"
      result <- mcpCallTool client "fixture_effect" (object [])
      result `shouldSatisfy` either ((== McpTransportError) . mcpErrorKind) (const False)
      readIORef opens `shouldReturn` 1

  describe "decodeRpcBody" $ do
    it "parses a plain application/json body" $
      decodeRpcBody (LBS8.pack "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"ok\":true}}")
        `shouldBe` Right envelope

    it "parses a text/event-stream body by concatenating data: lines" $
      decodeRpcBody
        ( LBS8.pack $
            "event: message\n"
              <> "data: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"ok\":true}}\n\n"
        )
        `shouldBe` Right envelope

    it "fails cleanly on a body that is neither JSON nor SSE" $
      decodeRpcBody (LBS8.pack "not json, no data lines")
        `shouldSatisfy` either (const True) (const False)

  describe "mcpTextContent" $ do
    it "joins text blocks and ignores non-text ones" $ do
      let result =
            object
              [ "content"
                  .= [ object ["type" .= s "text", "text" .= s "line one"],
                       object ["type" .= s "image", "data" .= s "..."],
                       object ["type" .= s "text", "text" .= s "line two"]
                     ]
              ]
      mcpTextContent result `shouldBe` "line one\nline two"

    it "returns empty when there is no content" $
      mcpTextContent (object []) `shouldBe` ""

  describe "toolResultError" $ do
    it "preserves structured tool metadata separately from display text" $ do
      let metadata = object ["camoufox/errorKind" .= s "session_gone"]
          result =
            object
              [ "isError" .= True,
                "content" .= [object ["type" .= s "text", "text" .= s "wording may change"]],
                "_meta" .= metadata
              ]
      mcpErrorMetadata <$> toolResultError result
        `shouldBe` Just (Just metadata)

    it "ignores metadata on successful tool results" $
      toolResultError (object ["isError" .= False, "_meta" .= object ["x" .= True]])
        `shouldBe` Nothing

  describe "classifyHttpError" $ do
    it "classifies a 400 with an attached session as session loss" $
      mcpErrorKind (classifyHttpError True 400 "gateway wording can change")
        `shouldBe` McpSessionError

    it "keeps the same status as an ordinary HTTP error before initialization" $
      mcpErrorKind (classifyHttpError False 400 "bad initialize request")
        `shouldBe` McpHttpError 400

    it "does not infer session loss from response prose" $
      mcpErrorKind (classifyHttpError True 500 "No valid session ID provided")
        `shouldBe` McpHttpError 500
  where
    s :: String -> String
    s = id

rpcResponse :: ByteString
rpcResponse =
  let body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"ok\":true}}"
   in "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nMcp-Session-Id: fixture-session\r\nContent-Length: "
        <> BS8.pack (show (BS8.length body))
        <> "\r\n\r\n"
        <> body
