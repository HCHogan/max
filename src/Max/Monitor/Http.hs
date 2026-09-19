module Max.Monitor.Http (handleHttpMonitor, validWebhookBaseUrl) where

import Data.Aeson (Value (String), eitherDecode', encode, object, (.=))
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Effectful
import Effectful.PostgreSQL (WithConnection)
import Max.DB.Monitor.Http (receiveHttpMonitor)
import Max.Monitor.Types
import Network.HTTP.Types
import Network.URI (URI (..), URIAuth (..), parseURI)
import Network.Wai (Request, Response, getRequestBodyChunk, requestHeaders, responseLBS)

validWebhookBaseUrl :: Text -> Bool
validWebhookBaseUrl value = case parseURI (T.unpack value) of
  Just uri
    | Just authority <- uri.uriAuthority ->
        elem uri.uriScheme ["http:", "https:"]
          && null authority.uriUserInfo
          && not (null authority.uriRegName)
          && null uri.uriQuery
          && null uri.uriFragment
  _ -> False

handleHttpMonitor :: (WithConnection :> es, IOE :> es) => Text -> Request -> Eff es Response
handleHttpMonitor hook request =
  case lookup hAuthorization request.requestHeaders >>= BS.stripPrefix "Bearer " of
    Nothing -> pure (reply status401 "unauthorized")
    Just rawToken | BS.length rawToken /= 64 -> pure (reply status401 "unauthorized")
    Just rawToken -> case (TE.decodeUtf8' rawToken, traverse TE.decodeUtf8' (lookup "Idempotency-Key" request.requestHeaders)) of
      (Right token, Right eventId)
        | maybe False (\key -> T.null (T.strip key) || T.length key > 256) eventId ->
            pure (reply status400 "invalid Idempotency-Key")
        | otherwise -> do
            body <- liftIO (readBody 65536 [])
            case body of
              Nothing -> pure (reply status413 "JSON body exceeds 64 KiB")
              Just bytes -> case eitherDecode' bytes of
                Left _ -> pure (reply status400 "invalid JSON")
                Right payload -> do
                  result <- receiveHttpMonitor hook token eventId payload
                  pure $ case result of
                    HttpAccepted -> reply status202 "accepted"
                    HttpDuplicate -> reply status202 "duplicate"
                    HttpUnauthorized -> reply status401 "unauthorized"
                    HttpGone -> reply status410 "monitor is cancelled or expired"
                    HttpBusy -> responseLBS status429 [(hContentType, "application/json"), (hRetryAfter, "60")] (encode (object ["error" .= String "monitor is busy; retry later"]))
      _ -> pure (reply status400 "invalid header encoding")
  where
    readBody remaining chunks = do
      chunk <- getRequestBodyChunk request
      if BS.null chunk
        then pure (Just (LBS.fromChunks (reverse chunks)))
        else
          if BS.length chunk > remaining
            then pure Nothing
            else readBody (remaining - BS.length chunk) (chunk : chunks)
    reply status detail = responseLBS status [(hContentType, "application/json"), (hCacheControl, "no-store")] (encode (object ["status" .= (detail :: Text)]))
