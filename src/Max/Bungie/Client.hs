-- | Bungie.net HTTP calls over the shared runtime: Platform requests with the
-- application key (and a player's bearer token when one is supplied), and the
-- OAuth token endpoint. Callers decide whose token to send.
module Max.Bungie.Client
  ( BungieFailure (..),
    renderBungieFailure,
    callBungie,
    exchangeAuthorizationCode,
    refreshAccessToken,
    authorizeUrl,
  )
where

import Data.Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Bifunctor (first)
import Data.ByteString qualified as BS
import Data.ByteString.Base64 qualified as B64
import Data.ByteString.Lazy qualified as LBS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Max.Bungie.Api
import Max.Bungie.Types (BungieConfig (..), TokenGrant, parseTokenGrant)
import Max.Http.Failure (TransportFailure (..), renderTransportFailure)
import Max.HttpRuntime (BufferedResponse (..), HttpPool (StandardPool), HttpRuntime, parseRequestEither, queryText, runBuffered)
import Network.HTTP.Client (Request (..), RequestBody (..), responseTimeoutMicro)
import Network.HTTP.Types (hAuthorization, hContentType, hUserAgent)

data BungieFailure
  = -- | Bungie answered with an error envelope.
    BungieRefused !BungieError
  | -- | No usable answer: transport, size or decoding failure.
    BungieUnreachable !Text
  deriving stock (Show, Eq)

renderBungieFailure :: BungieFailure -> Text
renderBungieFailure = \case
  BungieRefused e -> renderBungieError e
  BungieUnreachable detail -> "Bungie.net 不可达：" <> detail

-- | One Platform request. @Nothing@ body = GET.
callBungie :: HttpRuntime -> BungieConfig -> Int -> Maybe Text -> ApiTarget -> Maybe Value -> IO (Either BungieFailure Value)
callBungie runtime config bodyLimit bearer target body =
  parseRequestEither (T.unpack (targetUrl target)) >>= \case
    Left failure -> pure (Left (BungieUnreachable (renderTransportFailure failure)))
    Right request0 -> do
      let request =
            request0
              { method = maybe "GET" (const "POST") body,
                requestHeaders =
                  [("X-API-Key", TE.encodeUtf8 config.bcApiKey), (hUserAgent, userAgent config)]
                    <> [(hAuthorization, "Bearer " <> TE.encodeUtf8 token) | Just token <- [bearer]]
                    <> [(hContentType, "application/json") | Just _ <- [body]],
                requestBody = maybe mempty (RequestBodyLBS . encode) body,
                responseTimeout = responseTimeoutMicro 60_000_000
              }
      result <- runBuffered runtime StandardPool bodyLimit errorPreviewBytes request
      pure $ case result of
        Right response -> envelope response.body
        -- Error statuses carry the same envelope; read it from the preview.
        Left failure@(HttpStatusFailure _ _ preview _) -> case eitherDecodeStrict' preview of
          Right value | Left err <- decodeEnvelope value -> Left (BungieRefused err)
          _ -> Left (BungieUnreachable (renderTransportFailure failure))
        Left failure -> Left (BungieUnreachable (renderTransportFailure failure))
  where
    envelope bytes = case eitherDecodeStrict' bytes of
      Left err -> Left (BungieUnreachable ("无法解析 Bungie 响应：" <> T.pack err))
      Right value -> first BungieRefused (decodeEnvelope value)

-- | Bungie error envelopes are small; this keeps their Message intact.
errorPreviewBytes :: Int
errorPreviewBytes = 16384

userAgent :: BungieConfig -> BS.ByteString
userAgent config = TE.encodeUtf8 ("max/1.0 AppId/" <> config.bcClientId <> " (+https://github.com/HCHogan/max)")

-- | The page a player opens to approve access. zh-chs serves the consent
-- screen in Chinese; the redirect is the one registered for the application.
authorizeUrl :: BungieConfig -> Text -> Text
authorizeUrl config state =
  "https://www.bungie.net/zh-chs/OAuth/Authorize"
    <> queryText [("client_id", config.bcClientId), ("response_type", "code"), ("state", state)]

exchangeAuthorizationCode :: HttpRuntime -> BungieConfig -> Text -> IO (Either Text TokenGrant)
exchangeAuthorizationCode runtime config code =
  fmap (first renderTokenFailure) (tokenRequest runtime config [("grant_type", "authorization_code"), ("code", code)])

-- | @Left Nothing@: Bungie rejected the refresh token, so only a new login
-- helps. @Left (Just reason)@: a transient failure worth retrying later.
refreshAccessToken :: HttpRuntime -> BungieConfig -> Text -> IO (Either (Maybe Text) TokenGrant)
refreshAccessToken runtime config token =
  fmap (first classify) (tokenRequest runtime config [("grant_type", "refresh_token"), ("refresh_token", token)])
  where
    classify = \case
      TokenRejected _ -> Nothing
      other -> Just (renderTokenFailure other)

data TokenFailure = TokenRejected !Text | TokenUnavailable !Text

renderTokenFailure :: TokenFailure -> Text
renderTokenFailure = \case
  TokenRejected detail -> "Bungie 拒绝了授权：" <> detail
  TokenUnavailable detail -> "Bungie 授权服务不可用：" <> detail

tokenRequest :: HttpRuntime -> BungieConfig -> [(Text, Text)] -> IO (Either TokenFailure TokenGrant)
tokenRequest runtime config form =
  parseRequestEither "https://www.bungie.net/Platform/App/OAuth/Token/" >>= \case
    Left failure -> pure (Left (TokenUnavailable (renderTransportFailure failure)))
    Right request0 -> do
      let credentials = B64.encode (TE.encodeUtf8 (config.bcClientId <> ":" <> config.bcClientSecret))
          request =
            request0
              { method = "POST",
                requestHeaders =
                  [ (hAuthorization, "Basic " <> credentials),
                    (hContentType, "application/x-www-form-urlencoded"),
                    ("X-API-Key", TE.encodeUtf8 config.bcApiKey),
                    (hUserAgent, userAgent config)
                  ],
                requestBody = RequestBodyBS (TE.encodeUtf8 (T.drop 1 (queryText form))),
                responseTimeout = responseTimeoutMicro 30_000_000
              }
      result <- runBuffered runtime StandardPool 65536 errorPreviewBytes request
      pure $ case result of
        Right response -> case eitherDecodeStrict' response.body of
          Left err -> Left (TokenUnavailable (T.pack err))
          Right value -> first TokenUnavailable (parseTokenGrant value)
        -- OAuth errors are 400/401 with {"error": "invalid_grant", ...}.
        Left (HttpStatusFailure status _ preview _)
          | status `elem` [400, 401] -> Left (TokenRejected (oauthError preview))
        Left failure -> Left (TokenUnavailable (renderTransportFailure failure))
  where
    oauthError preview = case decode (LBS.fromStrict preview) of
      Just (Object o) | Just (String e) <- KeyMap.lookup "error" o ->
        e <> case KeyMap.lookup "error_description" o of
          Just (String d) -> ": " <> d
          _ -> ""
      _ -> TE.decodeUtf8Lenient (BS.take 200 preview)
