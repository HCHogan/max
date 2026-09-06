-- | Pure HTTP failures. Display text is diagnostic, never a retry signal.
module Max.Http.Failure
  ( TransportFailure (..),
    ResponseFailure (..),
    renderTransportFailure,
    renderResponseFailure,
    retryableResponseFailure,
    retryableStatus,
  )
where

import Data.Aeson (ToJSON (..), object, (.=))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Text (Text)
import Data.Text qualified as T
import Network.HTTP.Types.Header (ResponseHeaders)

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

-- | Decoding and stream completion add domain facts to transport failures.
data ResponseFailure
  = ResponseTransport !TransportFailure
  | ResponseDecode !Text
  | ResponseEmptyStream
  | ResponseMissingTerminal
  deriving stock (Eq, Show)

renderResponseFailure :: ResponseFailure -> Text
renderResponseFailure = \case
  ResponseTransport failure -> renderTransportFailure failure
  ResponseDecode detail -> detail
  ResponseEmptyStream -> "stream ended with no content"
  ResponseMissingTerminal -> "stream ended without a terminal frame"

instance ToJSON ResponseFailure where
  toJSON failure = object ["kind" .= kind, "detail" .= renderResponseFailure failure]
    where
      kind :: Text
      kind = case failure of
        ResponseTransport _ -> "transport"
        ResponseDecode _ -> "decode"
        ResponseEmptyStream -> "empty_stream"
        ResponseMissingTerminal -> "missing_terminal"

retryableResponseFailure :: ResponseFailure -> Bool
retryableResponseFailure = \case
  ResponseTransport transport -> case transport of
    ResponseTimeoutFailure -> True
    ConnectionTimeoutFailure -> True
    ConnectionFailed _ -> True
    ProxyFailure _ -> True
    ProtocolFailure _ -> True
    HttpStatusFailure code _ _ _ -> retryableStatus code
    RequestConstructionFailure _ -> False
    ResponseBodyLimitExceeded _ -> False
    TlsFailed _ -> False
  ResponseEmptyStream -> True
  ResponseMissingTerminal -> False
  ResponseDecode _ -> False

-- | Retry only explicit temporary HTTP statuses. A provider name or error
-- message in a 4xx body cannot turn rejected credentials or input into a
-- transient failure, and changing diagnostic wording cannot affect policy.
retryableStatus :: Int -> Bool
retryableStatus code = code == 408 || code == 429 || (code >= 500 && code <= 599)
