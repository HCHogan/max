-- |
-- A minimal Model Context Protocol client over the **Streamable HTTP**
-- transport, enough to drive an MCP server that exposes tools:
-- @initialize@ → @notifications/initialized@ → @tools/call@.
--
-- We talk plain HTTP to @127.0.0.1:<port>/mcp@ (a container on the
-- loopback, no TLS) through the shared "Max.HttpRuntime".  The client
-- remains a plain-IO handle; callers 'liftIO' into it.
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
    McpError (..),
    McpErrorKind (..),
    newMcpClient,
    mcpInitialize,
    mcpCallTool,
    mcpTerminate,
    renderMcpError,

    -- * Result helpers
    mcpTextContent,

    -- * Exposed for tests
    classifyHttpError,
    decodeRpcBody,
    toolResultError,
  )
where

import Control.Concurrent.STM
import Control.Monad (join)
import Data.Aeson
import Data.Aeson.Types (parseMaybe)
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy qualified as LBS
import Data.CaseInsensitive qualified as CI
import Data.Foldable (for_)
import Data.Maybe (isJust, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Max.HttpRuntime
  ( BufferedResponse (..),
    HttpPool (StandardPool),
    HttpRuntime,
    ResponseMetadata (headers),
    TransportFailure (..),
    parseRequestEither,
    renderTransportFailure,
    runBuffered,
  )
import Network.HTTP.Client
  ( Request (..),
    RequestBody (..),
  )
import Network.HTTP.Types.Header (ResponseHeaders)

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
    mcHttp :: !HttpRuntime,
    mcSession :: !(TVar (Maybe ByteString)),
    mcNextId :: !(TVar Int)
  }

-- | Stable classification at the MCP transport boundary.  Callers decide
-- recovery from this tag, never by inspecting provider or gateway prose.
data McpErrorKind
  = McpEndpointError
  | McpTransportError
  | McpHttpError !Int
  | McpSessionError
  | McpProtocolError
  | McpRemoteError
  | McpToolError
  deriving stock (Show, Eq)

data McpError = McpError
  { mcpErrorKind :: !McpErrorKind,
    mcpErrorMessage :: !Text,
    -- | Provider-owned structured metadata from an MCP tool result.
    -- Transport and protocol failures have no metadata.  Keeping this
    -- separate from the display message lets integrations make recovery
    -- decisions from stable tags instead of provider prose.
    mcpErrorMetadata :: !(Maybe Value)
  }
  deriving stock (Show, Eq)

renderMcpError :: McpError -> Text
renderMcpError = (.mcpErrorMessage)

-- | Build a client for @http://host:port/mcp@.  @hostHeader@ is the
-- value to send as @Host@ (see 'mcHost').  Does no I/O beyond
-- allocating the mutable cells; call 'mcpInitialize' before any tool
-- call.
newMcpClient :: HttpRuntime -> String -> String -> IO McpClient
newMcpClient runtime endpoint hostHeader =
  McpClient endpoint (BS8.pack hostHeader) runtime <$> newTVarIO Nothing <*> newTVarIO 0

protocolVersion :: Text
protocolVersion = "2025-06-18"

-- | Run the @initialize@ handshake and send the follow-up
-- @notifications/initialized@.  Captures the @Mcp-Session-Id@ response
-- header for subsequent requests.
mcpInitialize :: McpClient -> IO (Either McpError ())
mcpInitialize c = do
  -- Start a *fresh* handshake.  The server issues the session on this request
  -- and 404s an initialize that carries an unknown one; terminating first
  -- also prevents a failed notification/re-initialize cycle from leaking the
  -- gateway's previous stdio child.
  mcpTerminate c
  let params =
        object
          [ "protocolVersion" .= protocolVersion,
            "capabilities" .= object [],
            "clientInfo" .= object ["name" .= ("max" :: Text), "version" .= ("0.1" :: Text)]
          ]
  eres <- request c "initialize" params
  case eres of
    Left e -> pure (Left e)
    Right _ -> do
      initialized <- notify c "notifications/initialized"
      case initialized of
        Right () -> pure (Right ())
        Left err -> Left err <$ mcpTerminate c

-- | Call one tool.  Returns the JSON-RPC @result@ object (which for
-- MCP carries @content@ + @isError@), or a 'Left' with a transport /
-- protocol / tool error.
mcpCallTool :: McpClient -> Text -> Value -> IO (Either McpError Value)
mcpCallTool c name args = do
  let params = object ["name" .= name, "arguments" .= args]
  eres <- request c "tools/call" params
  pure $ case eres of
    Left e -> Left e
    Right result -> maybe (Right result) Left (toolResultError result)

-- | End this Streamable-HTTP session and release the gateway's stdio child.
-- The local token is forgotten before I/O, so cancellation or an unhealthy
-- gateway cannot make a dead client usable again.  Teardown is best-effort;
-- callers already own the stronger fallback of removing its container.
mcpTerminate :: McpClient -> IO ()
mcpTerminate c = do
  mSession <- atomically $ do
    current <- readTVar c.mcSession
    writeTVar c.mcSession Nothing
    pure current
  for_ mSession $ \sessionId -> do
    parseRequestEither c.mcEndpoint >>= \case
      Left _ -> pure ()
      Right req0 -> do
        let req =
              req0
                { method = "DELETE",
                  requestHeaders =
                    [ (CI.mk "Host", c.mcHost),
                      (CI.mk "Mcp-Session-Id", sessionId)
                    ]
                }
        _ <- runBuffered c.mcHttp StandardPool 4096 4096 req
        pure ()

-- | Decode the error half of a tool result while preserving provider-owned
-- metadata.  Success results return 'Nothing'.
toolResultError :: Value -> Maybe McpError
toolResultError result
  | parseMaybe (withObject "r" (.: "isError")) result == Just True =
      Just
        ( McpError
            McpToolError
            (mcpTextContent result)
            (join (parseMaybe (withObject "r" (.:? "_meta")) result))
        )
  | otherwise = Nothing

--------------------------------------------------------------------------------
-- JSON-RPC plumbing.

-- | A JSON-RPC request: allocate an id, POST, expect a @result@.
request :: McpClient -> Text -> Value -> IO (Either McpError Value)
request c method params = do
  n <- atomically $ do
    i <- readTVar c.mcNextId
    writeTVar c.mcNextId (i + 1)
    pure (i + 1)
  postRpc c (Just n) method params True

-- | A JSON-RPC notification: no id, no result body expected.
notify :: McpClient -> Text -> IO (Either McpError ())
notify c method = fmap (() <$) (postRpc c Nothing method (object []) False)

-- | Encode + POST a JSON-RPC message, attach the session header if we
-- have one, capture it from the response, and decode the result.
postRpc :: McpClient -> Maybe Int -> Text -> Value -> Bool -> IO (Either McpError Value)
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
  ereq <- parseRequestEither c.mcEndpoint
  case ereq of
    Left failure ->
      pure . Left $ McpError McpEndpointError ("bad MCP endpoint: " <> renderTransportFailure failure) Nothing
    Right req0 -> do
      let req =
            req0
              { method = "POST",
                requestHeaders = hdrs,
                requestBody = RequestBodyLBS (encode body)
              }
      runBuffered c.mcHttp StandardPool maxMcpResponseBytes statusPreviewBytes req >>= \case
        Left (HttpStatusFailure code responseHeaders responsePreview _) -> do
          captureSession c responseHeaders
          pure . Left $
            classifyHttpError
              (isJust sess)
              code
              ( "MCP HTTP "
                  <> T.pack (show code)
                  <> " ["
                  <> ctx
                  <> "]: "
                  <> T.take 200 (TE.decodeUtf8Lenient responsePreview)
              )
        Left failure ->
          pure . Left $
            McpError
              McpTransportError
              ("MCP request failed [" <> ctx <> "]: " <> renderTransportFailure failure)
              Nothing
        Right response -> do
          captureSession c response.metadata.headers
          if not expectResult
            then pure (Right Null)
            else case decodeRpcBody (LBS.fromStrict response.body) of
              Left err -> pure (Left (McpError McpProtocolError err Nothing))
              Right value -> pure (extractResult value)

captureSession :: McpClient -> ResponseHeaders -> IO ()
captureSession client responseHeaders =
  case lookup (CI.mk "Mcp-Session-Id") responseHeaders of
    Just sessionId -> atomically $ writeTVar client.mcSession (Just sessionId)
    Nothing -> pure ()

maxMcpResponseBytes :: Int
maxMcpResponseBytes = 32 * 1024 * 1024

statusPreviewBytes :: Int
statusPreviewBytes = 2048

-- | Classify an HTTP failure using transport state, not a gateway's
-- human-readable response body.  Streamable HTTP uses 400/404 for an
-- unknown session; without an attached session the same statuses remain
-- ordinary request failures.
classifyHttpError :: Bool -> Int -> Text -> McpError
classifyHttpError hadSession code message
  | hadSession && code `elem` [400, 404] = McpError McpSessionError message Nothing
  | otherwise = McpError (McpHttpError code) message Nothing

-- | Pull the @result@ out of a JSON-RPC envelope, or surface @error@.
extractResult :: Value -> Either McpError Value
extractResult v =
  case parseMaybe (withObject "rpc" (\o -> (,) <$> o .:? "result" <*> o .:? "error")) v of
    Just (Just result, _) -> Right result
    Just (_, Just err) -> Left (McpError McpRemoteError ("MCP error: " <> renderErr err) Nothing)
    _ -> Left (McpError McpProtocolError "MCP response had neither result nor error" Nothing)
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
