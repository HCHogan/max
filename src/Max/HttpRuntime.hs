module Max.HttpRuntime
  ( HttpRuntime,
    HttpPool (..),
    TransportFailure (..),
    ResponseMetadata (..),
    BufferedResponse (..),
    newHttpRuntime,
    httpRuntimeFromManagers,
    parseRequestEither,
    runBuffered,
    withStreamingResponse,
    readBodyBounded,
    classifyTransportException,
    renderTransportFailure,
  )
where

import Control.Exception (IOException, SomeException, displayException, fromException)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Text (Text)
import Data.Text qualified as T
import Max.Util (trySyncIO)
import Network.Connection (TLSSettings (..))
import Network.HTTP.Client
  ( BodyReader,
    HttpException (..),
    HttpExceptionContent (..),
    Manager,
    ManagerSettings (managerRetryableException),
    Request (checkResponse),
    brRead,
    newManager,
    parseRequest,
    responseBody,
    responseHeaders,
    responseStatus,
    withResponse,
  )
import Network.HTTP.Client.TLS (mkManagerSettings, tlsManagerSettings)
import Network.HTTP.Types.Header (ResponseHeaders)
import Network.HTTP.Types.Status (Status, statusCode, statusIsSuccessful)
import Network.TLS qualified as TLS
import System.X509 (getSystemCertificateStore)

-- | The deliberately small set of connection pools used by Max.  Relaxing
-- Extended Master Secret support is opt-in at each call site; ordinary HTTPS
-- never inherits the legacy-CDN concession by accident.
data HttpPool
  = StandardPool
  | LegacyEmsPool
  deriving stock (Eq, Show)

-- | Process-wide outbound HTTP resources.  A 'Manager' owns its connection
-- pool, so keeping these values at the application boundary is what makes
-- keep-alive reuse possible across otherwise unrelated features.
data HttpRuntime = HttpRuntime
  { standardManager :: Manager,
    legacyEmsManager :: Manager
  }

-- | Failures shared by all outbound HTTP users.  Response decoding remains a
-- caller concern and therefore is intentionally absent from this type.
data TransportFailure
  = RequestConstructionFailure Text
  | ResponseTimeoutFailure
  | ConnectionTimeoutFailure
  | ConnectionFailed Text
  | TlsFailed Text
  | ProxyFailure Text
  | ProtocolFailure Text
  | HttpStatusFailure Int ResponseHeaders ByteString Bool
  | ResponseBodyLimitExceeded Int
  deriving stock (Eq, Show)

data ResponseMetadata = ResponseMetadata
  { status :: Status,
    headers :: ResponseHeaders
  }
  deriving stock (Eq, Show)

data BufferedResponse = BufferedResponse
  { metadata :: ResponseMetadata,
    body :: ByteString
  }
  deriving stock (Eq, Show)

-- | Construct both long-lived pools.  http-client normally retries a request
-- once when a pooled connection has gone stale.  Max keeps retry policy in the
-- domain layer, so both managers explicitly disable that implicit replay.
newHttpRuntime :: IO HttpRuntime
newHttpRuntime = do
  standard <- newManager noImplicitRetryTlsSettings
  legacyEmsSettings <- legacyEmsManagerSettings
  legacyEms <- newManager legacyEmsSettings
  pure (HttpRuntime standard legacyEms)

-- | Injection seam for tests and application components that already own
-- managers.  Production startup should normally use 'newHttpRuntime'.
httpRuntimeFromManagers :: Manager -> Manager -> HttpRuntime
httpRuntimeFromManagers = HttpRuntime

managerFor :: HttpPool -> HttpRuntime -> Manager
managerFor StandardPool = (.standardManager)
managerFor LegacyEmsPool = (.legacyEmsManager)

parseRequestEither :: String -> IO (Either TransportFailure Request)
parseRequestEither raw = do
  result <- trySyncIO (parseRequest raw)
  pure $ case result of
    Right request -> Right request
    Left exception -> Left (classifyTransportException exception)

-- | Execute a request and fully buffer a successful response up to the given
-- limit.  Non-2xx bodies are represented only by a bounded diagnostic preview.
runBuffered ::
  HttpRuntime ->
  HttpPool ->
  Int ->
  Int ->
  Request ->
  IO (Either TransportFailure BufferedResponse)
runBuffered runtime pool bodyLimit previewLimit request = do
  result <- trySyncIO $ withResponse uncheckedRequest (managerFor pool runtime) $ \response -> do
    let responseMetadata =
          ResponseMetadata
            { status = responseStatus response,
              headers = responseHeaders response
            }
    if statusIsSuccessful responseMetadata.status
      then
        fmap (BufferedResponse responseMetadata)
          <$> readBodyBounded bodyLimit (responseBody response)
      else Left <$> statusFailure previewLimit responseMetadata.status responseMetadata.headers (responseBody response)
  pure $ either (Left . classifyTransportException) id result
  where
    uncheckedRequest = request {checkResponse = \_ _ -> pure ()}

-- | Scope a streaming response.  The callback cannot outlive the response;
-- http-client closes or releases the body on normal return, exceptions, and
-- asynchronous cancellation.  Max does not retry at this level.
withStreamingResponse ::
  HttpRuntime ->
  HttpPool ->
  Int ->
  Request ->
  (ResponseMetadata -> BodyReader -> IO a) ->
  IO (Either TransportFailure a)
withStreamingResponse runtime pool previewLimit request use = do
  result <- trySyncIO $ withResponse uncheckedRequest (managerFor pool runtime) $ \response -> do
    let responseMetadata =
          ResponseMetadata
            { status = responseStatus response,
              headers = responseHeaders response
            }
    if statusIsSuccessful responseMetadata.status
      then Right <$> use responseMetadata (responseBody response)
      else Left <$> statusFailure previewLimit responseMetadata.status responseMetadata.headers (responseBody response)
  pure $ either (Left . classifyTransportException) id result
  where
    uncheckedRequest = request {checkResponse = \_ _ -> pure ()}

-- | Read a body without allowing it to grow beyond the caller's memory budget.
-- A body exactly equal to the limit is accepted.
readBodyBounded :: Int -> BodyReader -> IO (Either TransportFailure ByteString)
readBodyBounded bodyLimit bodyReader
  | bodyLimit < 0 = pure (Left (ResponseBodyLimitExceeded bodyLimit))
  | otherwise = go bodyLimit []
  where
    go remaining chunks = do
      chunk <- brRead bodyReader
      if BS.null chunk
        then pure (Right (BS.concat (reverse chunks)))
        else
          if BS.length chunk > remaining
            then pure (Left (ResponseBodyLimitExceeded bodyLimit))
            else go (remaining - BS.length chunk) (chunk : chunks)

classifyTransportException :: SomeException -> TransportFailure
classifyTransportException exception =
  case fromException exception of
    Just (InvalidUrlException url reason) ->
      RequestConstructionFailure (T.pack (url <> ": " <> reason))
    Just (HttpExceptionRequest _ content) -> classifyHttpExceptionContent content
    Nothing ->
      case fromException exception of
        Just tlsException -> TlsFailed (T.pack (show (tlsException :: TLS.TLSException)))
        Nothing ->
          case fromException exception of
            Just ioException -> ConnectionFailed (T.pack (displayException (ioException :: IOException)))
            Nothing -> ProtocolFailure (T.pack (displayException exception))

renderTransportFailure :: TransportFailure -> Text
renderTransportFailure = \case
  RequestConstructionFailure message -> "invalid HTTP request: " <> message
  ResponseTimeoutFailure -> "HTTP response timed out"
  ConnectionTimeoutFailure -> "HTTP connection timed out"
  ConnectionFailed message -> "HTTP connection failed: " <> message
  TlsFailed message -> "TLS failed: " <> message
  ProxyFailure message -> "HTTP proxy failed: " <> message
  ProtocolFailure message -> "HTTP protocol failed: " <> message
  HttpStatusFailure code _ bodyPreview truncated ->
    "HTTP "
      <> T.pack (show code)
      <> if BS.null bodyPreview
        then ""
        else
          ": "
            <> T.pack (show bodyPreview)
            <> if truncated then "…" else ""
  ResponseBodyLimitExceeded bodyLimit ->
    "HTTP response exceeded " <> T.pack (show bodyLimit) <> " bytes"

noImplicitRetryTlsSettings :: ManagerSettings
noImplicitRetryTlsSettings =
  tlsManagerSettings {managerRetryableException = const False}

-- | Standard certificate validation with only missing RFC 7627 Extended
-- Master Secret support relaxed.  QQ media and some Bilibili video CDNs need
-- this; the system trust store and hostname checks remain enabled.
legacyEmsManagerSettings :: IO ManagerSettings
legacyEmsManagerSettings = do
  caStore <- getSystemCertificateStore
  let base = TLS.defaultParamsClient "" ""
      clientParams =
        base
          { TLS.clientShared =
              (TLS.clientShared base)
                { TLS.sharedCAStore = caStore
                },
            TLS.clientSupported =
              (TLS.clientSupported base)
                { TLS.supportedExtendedMainSecret = TLS.AllowEMS
                }
          }
  pure
    ( (mkManagerSettings (TLSSettings clientParams) Nothing)
        { managerRetryableException = const False
        }
    )

classifyHttpExceptionContent :: HttpExceptionContent -> TransportFailure
classifyHttpExceptionContent = \case
  ResponseTimeout -> ResponseTimeoutFailure
  ConnectionTimeout -> ConnectionTimeoutFailure
  ConnectionFailure exception -> classifyNestedConnectionFailure exception
  InternalException exception -> classifyNestedConnectionFailure exception
  ProxyConnectException host port proxyStatus ->
    ProxyFailure
      ( T.pack (show host)
          <> ":"
          <> T.pack (show port)
          <> " returned HTTP "
          <> T.pack (show (statusCode proxyStatus))
      )
  InvalidProxyEnvironmentVariable name value ->
    ProxyFailure (name <> "=" <> value)
  InvalidProxySettings message -> ProxyFailure message
  TlsNotSupported -> TlsFailed "TLS is not supported by this manager"
  StatusCodeException response bodyPreview ->
    HttpStatusFailure
      (statusCode (responseStatus response))
      (responseHeaders response)
      (BS.take defaultExceptionPreviewLimit bodyPreview)
      (BS.length bodyPreview > defaultExceptionPreviewLimit)
  content -> ProtocolFailure (T.pack (show content))

classifyNestedConnectionFailure :: SomeException -> TransportFailure
classifyNestedConnectionFailure exception =
  case fromException exception of
    Just tlsException -> TlsFailed (T.pack (show (tlsException :: TLS.TLSException)))
    Nothing -> ConnectionFailed (T.pack (displayException exception))

statusFailure :: Int -> Status -> ResponseHeaders -> BodyReader -> IO TransportFailure
statusFailure previewLimit responseStatus' responseHeaders' bodyReader = do
  (bodyPreview, truncated) <- readPreview previewLimit bodyReader
  pure (HttpStatusFailure (statusCode responseStatus') responseHeaders' bodyPreview truncated)

readPreview :: Int -> BodyReader -> IO (ByteString, Bool)
readPreview requestedLimit bodyReader = go (max 0 requestedLimit) []
  where
    go remaining chunks = do
      chunk <- brRead bodyReader
      if BS.null chunk
        then pure (BS.concat (reverse chunks), False)
        else
          if BS.length chunk > remaining
            then
              pure
                ( BS.concat (reverse (BS.take remaining chunk : chunks)),
                  True
                )
            else go (remaining - BS.length chunk) (chunk : chunks)

defaultExceptionPreviewLimit :: Int
defaultExceptionPreviewLimit = 1024
