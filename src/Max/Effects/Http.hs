{-# LANGUAGE TypeFamilies #-}

module Max.Effects.Http
  ( Http,
    runHttp,
    getBytes,
    getBytesQqCompatible,
    getBytesWith,
    getBytesWithLegacyTls,
    getFinalUrl,
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

data Http :: Effect where
  GetBytes :: HttpPool -> Text -> [(Text, Text)] -> Int -> Http m (Either Text (ByteString, Text))
  -- | Resolve one hop of redirection: the response's @Location@
  -- header.  Some link shorteners (b23.tv) are only readable this way.
  GetFinalUrl :: Text -> Http m (Either Text Text)

type instance DispatchOf Http = Dynamic

-- | Interpret downloads through the process-wide transport runtime.
runHttp :: IOE :> es => HttpRuntime -> Eff (Http : es) a -> Eff es a
runHttp runtime = interpret $ \_ -> \case
  GetBytes pool url headers limit -> liftIO (downloadIO runtime pool url headers limit)
  GetFinalUrl url -> liftIO (finalUrlIO runtime url)

-- | Fetch @url@, streaming-read body up to @limit@ bytes; reject if
-- exceeded. Returns @(bytes, primary-mime)@. The primary mime is the
-- @Content-Type@ header with any @;param@ tail stripped.
getBytes :: Http :> es => Text -> Int -> Eff es (Either Text (ByteString, Text))
getBytes url = getBytesWith url []

-- | Download media from QQ-controlled origins using the narrowly scoped TLS
-- compatibility pool.  Callers must opt in; ordinary downloads use the
-- standards-compliant pool through 'getBytes'.
getBytesQqCompatible :: Http :> es => Text -> Int -> Eff es (Either Text (ByteString, Text))
getBytesQqCompatible url limit = send (GetBytes LegacyEmsPool url [] limit)

-- | 'getBytes' with extra request headers — some origins such as Bilibili's
-- API refuse requests without @User-Agent@ / @Referer@.
getBytesWith :: Http :> es => Text -> [(Text, Text)] -> Int -> Eff es (Either Text (ByteString, Text))
getBytesWith url headers limit = send (GetBytes StandardPool url headers limit)

-- | Download from an origin that is known not to implement RFC 7627 EMS.
-- This is an explicit capability escape hatch for legacy CDNs; certificate
-- and hostname validation remain enabled.
getBytesWithLegacyTls :: Http :> es => Text -> [(Text, Text)] -> Int -> Eff es (Either Text (ByteString, Text))
getBytesWithLegacyTls url headers limit = send (GetBytes LegacyEmsPool url headers limit)

-- | Where does @url@ redirect to (single hop, @Location@ header)?
getFinalUrl :: Http :> es => Text -> Eff es (Either Text Text)
getFinalUrl url = send (GetFinalUrl url)

downloadIO :: HttpRuntime -> HttpPool -> Text -> [(Text, Text)] -> Int -> IO (Either Text (ByteString, Text))
downloadIO runtime pool url headers limit =
  parseRequestEither (T.unpack url) >>= \case
    Left failure -> pure (Left (renderTransportFailure failure))
    Right request0 -> do
      let request =
            request0
              { requestHeaders =
                  requestHeaders request0
                    <> [(CI.mk (TE.encodeUtf8 key), TE.encodeUtf8 value) | (key, value) <- headers]
              }
      runBuffered runtime pool limit statusPreviewBytes request >>= \case
        Left failure -> pure (Left (renderTransportFailure failure))
        Right response -> do
          let mime = case lookup hContentType response.metadata.headers of
                Just value -> primaryMime (TE.decodeUtf8 value)
                Nothing -> "application/octet-stream"
          pure (Right (response.body, mime))

finalUrlIO :: HttpRuntime -> Text -> IO (Either Text Text)
finalUrlIO runtime url =
  parseRequestEither (T.unpack url) >>= \case
    Left failure -> pure (Left (renderTransportFailure failure))
    Right request0 -> do
      let request = request0 {redirectCount = 0}
          location headers = TE.decodeUtf8 <$> lookup hLocation headers
      withStreamingResponse runtime StandardPool statusPreviewBytes request (\metadata _ -> pure metadata) >>= \case
        Right metadata ->
          pure (maybe (Left "no redirect") Right (location metadata.headers))
        Left (HttpStatusFailure code headers _ _) ->
          pure $
            maybe
              (Left ("no redirect (HTTP " <> T.pack (show code) <> ")"))
              Right
              (location headers)
        Left failure -> pure (Left (renderTransportFailure failure))

primaryMime :: Text -> Text
primaryMime = T.strip . fst . T.breakOn ";"

statusPreviewBytes :: Int
statusPreviewBytes = 512
