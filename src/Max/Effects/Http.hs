{-# LANGUAGE TypeFamilies #-}

module Max.Effects.Http
  ( Http,
    runHttp,
    getBytes,
    getBytesWith,
    getFinalUrl,
  )
where

import Control.Exception (SomeException)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.CaseInsensitive qualified as CI
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Effectful
import Effectful.Dispatch.Dynamic (interpret, send)
import Max.Util (trySyncIO)
import Network.Connection (TLSSettings (..))
import Network.HTTP.Client
  ( Manager,
    ManagerSettings,
    brRead,
    newManager,
    parseRequest,
    redirectCount,
    requestHeaders,
    responseBody,
    responseHeaders,
    responseStatus,
    withResponse,
  )
import Network.HTTP.Client.TLS (mkManagerSettings)
import Network.HTTP.Types.Header (hContentType, hLocation)
import Network.HTTP.Types.Status (statusCode)
import Network.TLS qualified as TLS
import System.X509 (getSystemCertificateStore)

data Http :: Effect where
  GetBytes :: Text -> [(Text, Text)] -> Int -> Http m (Either Text (ByteString, Text))
  -- | Resolve one hop of redirection: the response's @Location@
  -- header.  Some link shorteners (b23.tv) are only readable this way.
  GetFinalUrl :: Text -> Http m (Either Text Text)

type instance DispatchOf Http = Dynamic

-- | Build one shared 'Manager' (TLS-capable, internal connection pool) and
-- serve all requests through it.
runHttp :: IOE :> es => Eff (Http : es) a -> Eff es a
runHttp m = do
  settings <- liftIO lenientTlsManagerSettings
  mgr <- liftIO (newManager settings)
  interpret
    ( \_ -> \case
        GetBytes url headers limit -> liftIO (downloadIO mgr url headers limit)
        GetFinalUrl url -> liftIO (finalUrlIO mgr url)
    )
    m

-- | Like 'tlsManagerSettings' but with two QQ-CDN concessions:
--
--   * @supportedExtendedMainSecret = AllowEMS@ instead of the default
--     @RequireEMS@.  QQ's CDN doesn't implement RFC 7627; modern @tls@
--     otherwise rejects at handshake with @HandshakeFailure "peer
--     does not support Extended Main Secret"@.
--
--   * @sharedCAStore@ loaded from the system trust store.  The
--     handcrafted 'ClientParams' starts with an *empty* CA store, so
--     any server cert looks like "unknown CA"; we have to plug the
--     system bundle in explicitly (which is what 'tlsManagerSettings'
--     does behind the scenes).
--
-- Hostname / SNI is left as the placeholder pair; crypton-connection
-- overrides 'clientServerIdentification' per request based on the
-- actual hostname.
lenientTlsManagerSettings :: IO ManagerSettings
lenientTlsManagerSettings = do
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
  pure (mkManagerSettings (TLSSettings clientParams) Nothing)

-- | Fetch @url@, streaming-read body up to @limit@ bytes; reject if
-- exceeded. Returns @(bytes, primary-mime)@. The primary mime is the
-- @Content-Type@ header with any @;param@ tail stripped.
getBytes :: Http :> es => Text -> Int -> Eff es (Either Text (ByteString, Text))
getBytes url = getBytesWith url []

-- | 'getBytes' with extra request headers — some origins (bilibili's
-- API and CDN) refuse requests without @User-Agent@ / @Referer@.
getBytesWith :: Http :> es => Text -> [(Text, Text)] -> Int -> Eff es (Either Text (ByteString, Text))
getBytesWith url headers limit = send (GetBytes url headers limit)

-- | Where does @url@ redirect to (single hop, @Location@ header)?
getFinalUrl :: Http :> es => Text -> Eff es (Either Text Text)
getFinalUrl url = send (GetFinalUrl url)

downloadIO :: Manager -> Text -> [(Text, Text)] -> Int -> IO (Either Text (ByteString, Text))
downloadIO mgr url headers limit = do
  eres <- trySyncIO $ do
    req0 <- parseRequest (T.unpack url)
    let req =
          req0
            { requestHeaders =
                requestHeaders req0
                  <> [(CI.mk (TE.encodeUtf8 k), TE.encodeUtf8 v) | (k, v) <- headers]
            }
    withResponse req mgr $ \resp -> do
      let sc = statusCode (responseStatus resp)
      if sc >= 400
        then pure (Left ("HTTP " <> T.pack (show sc)))
        else do
          let mime = case lookup hContentType (responseHeaders resp) of
                Just v -> primaryMime (TE.decodeUtf8 v)
                Nothing -> "application/octet-stream"
          chunks <- readChunks (responseBody resp) limit []
          pure $ fmap (,mime) chunks
  case eres :: Either SomeException (Either Text (ByteString, Text)) of
    Right r -> pure r
    Left e -> pure (Left (T.pack (show e)))
  where
    readChunks body remaining acc
      | remaining <= 0 = pure (Left "exceeded size limit")
      | otherwise = do
          chunk <- brRead body
          if BS.null chunk
            then pure (Right (BS.concat (reverse acc)))
            else readChunks body (remaining - BS.length chunk) (chunk : acc)

finalUrlIO :: Manager -> Text -> IO (Either Text Text)
finalUrlIO mgr url = do
  eres <- trySyncIO $ do
    req0 <- parseRequest (T.unpack url)
    let req = req0 {redirectCount = 0}
    withResponse req mgr $ \resp ->
      pure $ case lookup hLocation (responseHeaders resp) of
        Just loc -> Right (TE.decodeUtf8 loc)
        Nothing -> Left ("no redirect (HTTP " <> T.pack (show (statusCode (responseStatus resp))) <> ")")
  case eres :: Either SomeException (Either Text Text) of
    Right r -> pure r
    Left e -> pure (Left (T.pack (show e)))

primaryMime :: Text -> Text
primaryMime = T.strip . fst . T.breakOn ";"
