{-# LANGUAGE TypeFamilies #-}

module Max.Effects.Http
  ( Http,
    runHttp,
    getBytes,
  )
where

import Control.Exception (SomeException, try)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Effectful
import Effectful.Dispatch.Dynamic (interpret, send)
import Network.Connection (TLSSettings (..))
import Network.HTTP.Client
  ( Manager,
    ManagerSettings,
    brRead,
    newManager,
    parseRequest,
    responseBody,
    responseHeaders,
    responseStatus,
    withResponse,
  )
import Network.HTTP.Client.TLS (mkManagerSettings)
import Network.HTTP.Types.Header (hContentType)
import Network.HTTP.Types.Status (statusCode)
import Network.TLS qualified as TLS
import System.X509 (getSystemCertificateStore)

data Http :: Effect where
  GetBytes :: Text -> Int -> Http m (Either Text (ByteString, Text))

type instance DispatchOf Http = Dynamic

-- | Build one shared 'Manager' (TLS-capable, internal connection pool) and
-- serve all 'GetBytes' calls through it.
runHttp :: IOE :> es => Eff (Http : es) a -> Eff es a
runHttp m = do
  settings <- liftIO lenientTlsManagerSettings
  mgr <- liftIO (newManager settings)
  interpret
    ( \_ -> \case
        GetBytes url limit -> liftIO (downloadIO mgr url limit)
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
getBytes url limit = send (GetBytes url limit)

downloadIO :: Manager -> Text -> Int -> IO (Either Text (ByteString, Text))
downloadIO mgr url limit = do
  eres <- try $ do
    req <- parseRequest (T.unpack url)
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

primaryMime :: Text -> Text
primaryMime = T.strip . fst . T.breakOn ";"
