-- |
-- A minimal Model Context Protocol client over the **Streamable HTTP**
-- transport, enough to drive an MCP server that exposes tools:
-- @initialize@ → @notifications/initialized@ → @tools/call@.
--
-- We talk plain HTTP to @127.0.0.1:<port>/mcp@ (a container on the
-- loopback, no TLS) via @http-client@ directly — same spirit as
-- "Max.Sandbox.Docker" shelling out to the @docker@ CLI: keep the
-- side-effecting transport in 'IO', let callers 'liftIO' into it.
--
-- == Response shape
--
-- Streamable HTTP lets the server answer a POST either as a single
-- @application/json@ body or as a short @text/event-stream@ (one or
-- more @data:@ lines) that it closes once the response is delivered.
-- 'decodeRpcBody' accepts both: it tries whole-body JSON first, then
-- falls back to concatenating @data:@ lines.  We never hold a
-- streaming connection open, so no special streaming machinery is
-- needed for request/response tool calls.
module Max.MCP.Client
  ( McpClient,
    newMcpClient,
    mcpInitialize,
    mcpCallTool,
    -- * Result helpers
    mcpTextContent,
    -- * Exposed for tests
    decodeRpcBody,
  )
where

import Control.Concurrent.STM
import Control.Exception (SomeException)
import Data.Aeson
import Data.Aeson.Types (parseMaybe)
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy qualified as LBS
import Data.CaseInsensitive qualified as CI
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Max.Util (trySyncIO)
import Network.HTTP.Client
  ( Manager,
    Request (..),
    RequestBody (..),
    httpLbs,
    parseRequest,
    responseBody,
    responseHeaders,
    responseStatus,
  )
import Network.HTTP.Types.Status (statusCode)

-- | One MCP session against a single server endpoint.  The session id
-- (handed back by the server on @initialize@) and the JSON-RPC request
-- counter are mutable so a single client value drives a whole
-- conversation.
data McpClient = McpClient
  { mcEndpoint :: !String,
    -- | Value for the @Host@ request header.  Some MCP servers enforce
    -- DNS-rebinding protection: playwright-mcp 403s unless @Host@
    -- matches the address it bound to (e.g. @localhost:8931@).  We
    -- reach servers via a docker-published @127.0.0.1:<random>@ port,
    -- so we send the container-internal host explicitly rather than
    -- the connect host.
    mcHost :: !ByteString,
    mcManager :: !Manager,
    mcSession :: !(TVar (Maybe ByteString)),
    mcNextId :: !(TVar Int)
  }

-- | Build a client for @http://host:port/mcp@.  @hostHeader@ is the
-- value to send as @Host@ (see 'mcHost').  Does no I/O beyond
-- allocating the mutable cells; call 'mcpInitialize' before any tool
-- call.
newMcpClient :: Manager -> String -> String -> IO McpClient
newMcpClient mgr endpoint hostHeader =
  McpClient endpoint (BS8.pack hostHeader) mgr <$> newTVarIO Nothing <*> newTVarIO 0

protocolVersion :: Text
protocolVersion = "2025-06-18"

-- | Run the @initialize@ handshake and send the follow-up
-- @notifications/initialized@.  Captures the @Mcp-Session-Id@ response
-- header for subsequent requests.
mcpInitialize :: McpClient -> IO (Either Text ())
mcpInitialize c = do
  -- Start a *fresh* handshake: drop any prior session id first.  The
  -- server issues the session on this request and 404s an initialize
  -- that carries an unknown one — so re-initializing to recover from a
  -- stale/expired session must not send the dead id.
  atomically $ writeTVar c.mcSession Nothing
  let params =
        object
          [ "protocolVersion" .= protocolVersion,
            "capabilities" .= object [],
            "clientInfo" .= object ["name" .= ("max" :: Text), "version" .= ("0.1" :: Text)]
          ]
  eres <- request c "initialize" params
  case eres of
    Left e -> pure (Left e)
    Right _ -> Right <$> notify c "notifications/initialized"

-- | Call one tool.  Returns the JSON-RPC @result@ object (which for
-- MCP carries @content@ + @isError@), or a 'Left' with a transport /
-- protocol / tool error.
mcpCallTool :: McpClient -> Text -> Value -> IO (Either Text Value)
mcpCallTool c name args = do
  let params = object ["name" .= name, "arguments" .= args]
  eres <- request c "tools/call" params
  pure $ case eres of
    Left e -> Left e
    Right result
      | isToolError result -> Left (mcpTextContent result)
      | otherwise -> Right result
  where
    isToolError v = parseMaybe (withObject "r" (.: "isError")) v == Just True

--------------------------------------------------------------------------------
-- JSON-RPC plumbing.

-- | A JSON-RPC request: allocate an id, POST, expect a @result@.
request :: McpClient -> Text -> Value -> IO (Either Text Value)
request c method params = do
  n <- atomically $ do
    i <- readTVar c.mcNextId
    writeTVar c.mcNextId (i + 1)
    pure (i + 1)
  postRpc c (Just n) method params True

-- | A JSON-RPC notification: no id, no result body expected.
notify :: McpClient -> Text -> IO ()
notify c method = () <$ postRpc c Nothing method (object []) False

-- | Encode + POST a JSON-RPC message, attach the session header if we
-- have one, capture it from the response, and decode the result.
postRpc :: McpClient -> Maybe Int -> Text -> Value -> Bool -> IO (Either Text Value)
postRpc c mId method params expectResult = do
  sess <- readTVarIO c.mcSession
  let body =
        object $
          [ "jsonrpc" .= ("2.0" :: Text),
            "method" .= method
          ]
            <> maybe [] (\i -> ["id" .= i]) mId
            <> ["params" .= params | params /= object []]
      hdrs =
        [ (CI.mk "Host", c.mcHost),
          (CI.mk "Content-Type", "application/json"),
          (CI.mk "Accept", "application/json, text/event-stream")
        ]
          <> maybe [] (\s -> [(CI.mk "Mcp-Session-Id", s)]) sess
      -- Diagnostic tag folded into error messages: which endpoint, which
      -- method, and whether we attached a session id.
      ctx =
        method
          <> " "
          <> T.pack c.mcEndpoint
          <> " sid="
          <> maybe "none" (T.take 8 . TE.decodeUtf8) sess
  ereq <- trySyncIO (parseRequest ("POST " <> c.mcEndpoint))
  case ereq of
    Left (e :: SomeException) -> pure (Left ("bad MCP endpoint: " <> T.pack (show e)))
    Right req0 -> do
      let req =
            req0
              { requestHeaders = hdrs,
                requestBody = RequestBodyLBS (encode body)
              }
      eresp <- trySyncIO (httpLbs req c.mcManager)
      case eresp of
        Left (e :: SomeException) -> pure (Left ("MCP request failed [" <> ctx <> "]: " <> T.pack (show e)))
        Right resp -> do
          -- Capture / refresh the session id whenever the server sends one.
          case lookup (CI.mk "Mcp-Session-Id") (responseHeaders resp) of
            Just s -> atomically $ writeTVar c.mcSession (Just s)
            Nothing -> pure ()
          let code = statusCode (responseStatus resp)
          if code >= 300
            then pure (Left ("MCP HTTP " <> T.pack (show code) <> " [" <> ctx <> "]: " <> shortBody resp))
            else
              if not expectResult
                then pure (Right Null)
                else case decodeRpcBody (responseBody resp) of
                  Left e -> pure (Left e)
                  Right v -> pure (extractResult v)
  where
    shortBody r = T.take 200 (TE.decodeUtf8 (LBS.toStrict (responseBody r)))

-- | Pull the @result@ out of a JSON-RPC envelope, or surface @error@.
extractResult :: Value -> Either Text Value
extractResult v =
  case parseMaybe (withObject "rpc" (\o -> (,) <$> o .:? "result" <*> o .:? "error")) v of
    Just (Just result, _) -> Right result
    Just (_, Just err) -> Left ("MCP error: " <> renderErr err)
    _ -> Left "MCP response had neither result nor error"
  where
    renderErr e =
      case parseMaybe (withObject "e" (.: "message")) e of
        Just (m :: Text) -> m
        Nothing -> T.take 200 (TE.decodeUtf8 (LBS.toStrict (encode e)))

-- | Decode a Streamable-HTTP response body: whole-body JSON first,
-- then a @text/event-stream@ fallback that concatenates @data:@ lines.
decodeRpcBody :: LBS.ByteString -> Either Text Value
decodeRpcBody body =
  case eitherDecode body of
    Right v -> Right v
    Left _ ->
      let txt = TE.decodeUtf8 (LBS.toStrict body)
          dataLines =
            mapMaybe
              (\l -> if "data:" `T.isPrefixOf` l then Just (T.strip (T.drop 5 l)) else Nothing)
              (T.lines txt)
          joined = T.concat dataLines
       in if T.null joined
            then Left ("unparseable MCP response: " <> T.take 200 txt)
            else case eitherDecode (LBS.fromStrict (TE.encodeUtf8 joined)) of
              Right v -> Right v
              Left e -> Left ("bad SSE JSON: " <> T.pack e)

--------------------------------------------------------------------------------
-- Result helpers.

-- | Flatten an MCP tool @result@'s @content@ array to its text blocks,
-- joined by newlines.  Non-text blocks (images) are ignored here — the
-- browser tool surfaces snapshots, which are text.
mcpTextContent :: Value -> Text
mcpTextContent v =
  case parseMaybe parser v of
    Just ts -> T.intercalate "\n" ts
    Nothing -> ""
  where
    parser = withObject "result" $ \o -> do
      blocks <- o .:? "content" .!= []
      pure $ mapMaybe textOf blocks
    textOf b = parseMaybe (withObject "b" (\o -> o .: "text")) b
