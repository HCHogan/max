-- |
-- Shared JSON-POST transport for the wreq-based API clients (the
-- OpenAI/Anthropic chat calls in "Max.Effects.LLM", the Tavily call
-- in "Max.Tools.Search").
module Max.Wreq
  ( postAndParse,
  )
where

import Control.Exception (SomeException)
import Control.Lens ((&), (.~), (?~), (^.))
import Data.Aeson (Value, eitherDecode, object, (.=))
import Data.Aeson.Types (Parser, parseEither)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Effectful
import Effectful.Log
import Effectful.Wreq qualified as W
import Max.Util (trySyncIO)
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Network.HTTP.Types.Status (statusCode)
import Network.Wreq qualified as Wreq
import Network.Wreq.Lens qualified as WL
import System.Timeout (timeout)

-- | POST @body@ to @url@, parse the JSON response with @parser@.
--
-- The timeout is enforced twice: http-client's
-- 'HTTP.managerResponseTimeout' is raised to @secs@ (otherwise the
-- manager's built-in 30s default kills any LLM generation slower than
-- that — non-streaming endpoints send nothing until the completion is
-- done), and a 'System.Timeout.timeout' wraps the whole call as the
-- wallclock belt-and-braces.
--
-- Surfaces structured 'Left' errors for timeout / transport /
-- HTTP-status / JSON-parse / extract failures with the response body
-- preview attached so log readers see what the upstream actually
-- sent.  Non-2xx never throws ('WL.checkResponse' is overridden
-- here); callers just build headers on top of 'Wreq.defaults'.
postAndParse ::
  (W.Wreq :> es, Log :> es, IOE :> es) =>
  -- | Timeout, seconds.
  Int ->
  Wreq.Options ->
  String -> -- url
  BS.ByteString -> -- body
  (Value -> Parser a) ->
  Eff es (Either Text a)
postAndParse secs opts url body parser = do
  let mgrSettings =
        tlsManagerSettings
          { HTTP.managerResponseTimeout =
              HTTP.responseTimeoutMicro (secs * 1_000_000)
          }
      opts' =
        opts
          & WL.manager .~ Left mgrSettings
          & WL.checkResponse ?~ (\_ _ -> pure ())
  res <- withRunInIO $ \run ->
    timeout (secs * 1_000_000) $
      trySyncIO (run (W.postWith opts' url body))
  case res of
    Nothing -> pure (Left "request timed out")
    Just (Left e) -> pure (Left ("http: " <> T.pack (show (e :: SomeException))))
    Just (Right resp) -> do
      let code = statusCode (resp ^. WL.responseStatus)
          rbody = resp ^. WL.responseBody
      if code >= 400
        then do
          -- 4xx bodies like "invalid_request_error" are
          -- undiagnosable without seeing what we actually sent —
          -- log a (truncated) copy of the request alongside.
          logAttention "http error request dump" $
            object
              [ "url" .= T.pack url,
                "status" .= code,
                "request_body" .= T.take 4000 (TE.decodeUtf8Lenient body)
              ]
          pure $
            Left $
              "HTTP "
                <> T.pack (show code)
                <> ": "
                <> T.take 500 (TE.decodeUtf8Lenient (LBS.toStrict rbody))
        else
          let bodyPreview =
                T.take 800 (TE.decodeUtf8Lenient (LBS.toStrict rbody))
           in pure $ case eitherDecode rbody of
                Left e ->
                  Left ("parse: " <> T.pack e <> "\nbody: " <> bodyPreview)
                Right v -> case parseEither parser v of
                  Left e ->
                    Left ("extract: " <> T.pack e <> "\nbody: " <> bodyPreview)
                  Right r -> Right r
