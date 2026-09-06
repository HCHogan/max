{-# LANGUAGE TypeFamilies #-}

module Max.Effects.Http
  ( Http,
    runHttp,
    getBytes,
    getQQMedia,
    getBytesWith,
    getBilibiliMedia,
    getFinalUrl,
    DownloadError (..),
    renderDownloadError,
  )
where

import Data.ByteString (ByteString)
import Data.CaseInsensitive qualified as CI
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Effectful
import Effectful.Dispatch.Dynamic (interpret, send)
import Max.HttpRuntime
  ( BufferedResponse (..),
    HttpPool (..),
    HttpRuntime,
    ResponseMetadata (..),
    TransportFailure (..),
    parseRequestEither,
    renderTransportFailure,
    runBuffered,
    withStreamingResponse,
  )
import Network.HTTP.Client
  ( redirectCount,
    requestHeaders,
  )
import Network.HTTP.Types.Header (hContentType, hLocation)

-- | The source says why an adapter downloads; transport/TLS choices belong
-- to this interpreter and never become caller-selected manager capabilities.
data DownloadSource = WebDownload | QQMedia | BilibiliMedia

data DownloadError
  = DownloadTransport !TransportFailure
  | NoRedirect !(Maybe Int)
  | InvalidDownloadLimit !Int
  | InvalidResponseHeader !Text
  deriving stock (Eq, Show)

data Http :: Effect where
  GetBytes :: DownloadSource -> Text -> [(Text, Text)] -> Int -> Http m (Either DownloadError (ByteString, Text))
  -- | Resolve one hop of redirection: the response's @Location@
  -- header.  Some link shorteners (b23.tv) are only readable this way.
  GetFinalUrl :: Text -> Http m (Either DownloadError Text)

type instance DispatchOf Http = Dynamic

-- | Interpret downloads through the process-wide transport runtime.
runHttp :: (IOE :> es) => HttpRuntime -> Eff (Http : es) a -> Eff es a
runHttp runtime = interpret $ \_ -> \case
  GetBytes source url headers limit -> liftIO (downloadIO runtime (downloadPool source) url headers limit)
  GetFinalUrl url -> liftIO (finalUrlIO runtime url)

-- | Fetch @url@, streaming-read body up to @limit@ bytes; reject if
-- exceeded. Returns @(bytes, primary-mime)@. The primary mime is the
-- @Content-Type@ header with any @;param@ tail stripped.
getBytes :: (Http :> es) => Text -> Int -> Eff es (Either DownloadError (ByteString, Text))
getBytes url = getBytesWith url []

-- | QQ media download. The interpreter owns this adapter's transport policy.
getQQMedia :: (Http :> es) => Text -> Int -> Eff es (Either DownloadError (ByteString, Text))
getQQMedia url limit = send (GetBytes QQMedia url [] limit)

-- | 'getBytes' with extra request headers — some origins such as Bilibili's
-- API refuse requests without @User-Agent@ / @Referer@.
getBytesWith :: (Http :> es) => Text -> [(Text, Text)] -> Int -> Eff es (Either DownloadError (ByteString, Text))
getBytesWith url headers limit = send (GetBytes WebDownload url headers limit)

-- | Bilibili CDN media download, distinct from its ordinary JSON API calls.
getBilibiliMedia :: (Http :> es) => Text -> [(Text, Text)] -> Int -> Eff es (Either DownloadError (ByteString, Text))
getBilibiliMedia url headers limit = send (GetBytes BilibiliMedia url headers limit)

-- | Where does @url@ redirect to (single hop, @Location@ header)?
getFinalUrl :: (Http :> es) => Text -> Eff es (Either DownloadError Text)
getFinalUrl url = send (GetFinalUrl url)

downloadIO :: HttpRuntime -> HttpPool -> Text -> [(Text, Text)] -> Int -> IO (Either DownloadError (ByteString, Text))
downloadIO _ _ _ _ limit | limit <= 0 = pure (Left (InvalidDownloadLimit limit))
downloadIO runtime pool url headers limit =
  parseRequestEither (T.unpack url) >>= \case
    Left failure -> pure (Left (DownloadTransport failure))
    Right request0 -> do
      let request =
            request0
              { requestHeaders =
                  requestHeaders request0
                    <> [(CI.mk (TE.encodeUtf8 key), TE.encodeUtf8 value) | (key, value) <- headers]
              }
      runBuffered runtime pool limit statusPreviewBytes request >>= \case
        Left failure -> pure (Left (DownloadTransport failure))
        Right response -> pure $ do
          mime <- maybe (Right "application/octet-stream") (fmap primaryMime . decodeHeader "Content-Type") (lookup hContentType response.metadata.headers)
          Right (response.body, mime)

finalUrlIO :: HttpRuntime -> Text -> IO (Either DownloadError Text)
finalUrlIO runtime url =
  parseRequestEither (T.unpack url) >>= \case
    Left failure -> pure (Left (DownloadTransport failure))
    Right request0 -> do
      let request = request0 {redirectCount = 0}
          location code headers = case lookup hLocation headers of
            Nothing -> Left (NoRedirect code)
            Just raw -> decodeHeader "Location" raw
      withStreamingResponse runtime StandardPool statusPreviewBytes request (\metadata _ -> pure metadata) >>= \case
        Right metadata -> pure (location Nothing metadata.headers)
        Left (HttpStatusFailure code headers _ _)
          | code >= 300 && code < 400 -> pure (location (Just code) headers)
        Left failure -> pure (Left (DownloadTransport failure))

downloadPool :: DownloadSource -> HttpPool
downloadPool WebDownload = StandardPool
downloadPool QQMedia = LegacyEmsPool
downloadPool BilibiliMedia = LegacyEmsPool

decodeHeader :: Text -> ByteString -> Either DownloadError Text
decodeHeader name = either (const (Left (InvalidResponseHeader name))) Right . TE.decodeUtf8'

-- | Render only at model, log or UI boundaries. Retry/control callers retain
-- the transport constructor, including status, timeout and size-limit facts.
renderDownloadError :: DownloadError -> Text
renderDownloadError = \case
  DownloadTransport failure -> renderTransportFailure failure
  NoRedirect Nothing -> "no redirect"
  NoRedirect (Just code) -> "no redirect (HTTP " <> T.pack (show code) <> ")"
  InvalidDownloadLimit limit -> "download limit must be positive: " <> T.pack (show limit)
  InvalidResponseHeader name -> "invalid UTF-8 in " <> name <> " header"

primaryMime :: Text -> Text
primaryMime = T.strip . fst . T.breakOn ";"

statusPreviewBytes :: Int
statusPreviewBytes = 512
