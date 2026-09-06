-- |
-- Shared buffered JSON-POST transport for the OpenAI/Anthropic clients and
-- Tavily.  Connection ownership lives in 'Max.HttpRuntime'; this module owns
-- only retry policy and JSON decoding.
module Max.Http.Json
  ( postAndParse,
    postAndParseRetrying,
    defaultRetryDelaysSecs,
    replyRetryDelaysSecs,

    -- * Exposed for tests
    retryableStatus,
  )
where

import Control.Concurrent (threadDelay)
import Data.Aeson (Value (..), decode, eitherDecodeStrict', object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (Parser, parseEither)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Foldable (toList)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Effectful
import Effectful.Log (Log, logAttention)
import Max.Http.Failure (ResponseFailure (..), renderResponseFailure, retryableResponseFailure, retryableStatus)
import Max.HttpRuntime
  ( BufferedResponse (body),
    HttpPool (StandardPool),
    HttpRuntime,
    TransportFailure (..),
    parseRequestEither,
    runBuffered,
  )
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Types.Header (Header)
import System.Timeout (timeout)

-- | Backoff schedule for background LLM calls (intent classifiers,
-- captions, memory extraction): two retries, kept deliberately shallow.
defaultRetryDelaysSecs :: [Int]
defaultRetryDelaysSecs = [2, 8]

-- | Backoff schedule for the streamed reply call.  It is longer because this
-- is the failure the group actually sees and relay outages often last minutes.
replyRetryDelaysSecs :: [Int]
replyRetryDelaysSecs = [2, 8, 20, 45, 90]

postAndParse ::
  (Log :> es, IOE :> es) =>
  HttpRuntime ->
  Int ->
  [Header] ->
  String ->
  BS.ByteString ->
  (Value -> Parser a) ->
  Eff es (Either ResponseFailure a)
postAndParse runtime = postAndParseRetrying runtime []

-- | POST one buffered JSON request.  Only this domain layer retries, using the
-- supplied schedule; the shared managers themselves never replay requests.
postAndParseRetrying ::
  (Log :> es, IOE :> es) =>
  HttpRuntime ->
  [Int] ->
  Int ->
  [Header] ->
  String ->
  BS.ByteString ->
  (Value -> Parser a) ->
  Eff es (Either ResponseFailure a)
postAndParseRetrying runtime delays secs headers url requestBody parser = go delays
  where
    go remaining = do
      result <- attempt
      case result of
        Left failure
          | retryableResponseFailure failure,
            delay : rest <- remaining -> do
              logAttention "http: retrying" $
                object
                  [ "url" .= T.pack url,
                    "delay_s" .= delay,
                    "error" .= renderResponseFailure failure
                  ]
              liftIO (threadDelay (delay * 1_000_000))
              go rest
        _ -> pure result

    attempt = do
      result <- liftIO $ timeout (secs * 1_000_000) $ do
        parseRequestEither url >>= \case
          Left failure -> pure (Left failure)
          Right request0 ->
            runBuffered
              runtime
              StandardPool
              maxBufferedResponseBytes
              statusPreviewBytes
              request0
                { HTTP.method = "POST",
                  HTTP.requestHeaders = headers,
                  HTTP.requestBody = HTTP.RequestBodyBS requestBody,
                  HTTP.responseTimeout =
                    HTTP.responseTimeoutMicro (secs * 1_000_000)
                }
      case result of
        Nothing -> pure (Left (ResponseTransport ResponseTimeoutFailure))
        Just (Left failure) -> do
          let domainFailure = ResponseTransport failure
          case failure of
            HttpStatusFailure code _ _ _ -> do
              -- Keep the existing request diagnostics: provider 4xxs are
              -- otherwise impossible to debug when the malformed block is
              -- later than the system-prompt prefix.
              logAttention "http error request dump" $
                object $
                  [ "url" .= T.pack url,
                    "status" .= code,
                    "request_body" .= T.take 4000 (TE.decodeUtf8Lenient requestBody)
                  ]
                    <> maybe [] (\shape -> ["request_shape" .= shape]) (requestShape requestBody)
            _ -> pure ()
          pure (Left domainFailure)
        Just (Right response) -> do
          let responseBody = response.body
              responsePreview = T.take 800 (TE.decodeUtf8Lenient responseBody)
          pure $ case eitherDecodeStrict' responseBody of
            Left err ->
              Left (ResponseDecode ("parse: " <> T.pack err <> "\nbody: " <> responsePreview))
            Right value -> case parseEither parser value of
              Left err ->
                Left (ResponseDecode ("extract: " <> T.pack err <> "\nbody: " <> responsePreview))
              Right parsed -> Right parsed

-- | One line per chat message for safe diagnostics.  'Nothing' for non-chat
-- JSON such as the Tavily request.
requestShape :: BS.ByteString -> Maybe [Text]
requestShape bytes = do
  Object root <- decode (LBS.fromStrict bytes)
  Array messages <- KM.lookup "messages" root
  pure (map messageShape (toList messages))
  where
    tshow :: (Show a) => a -> Text
    tshow = T.pack . show

    messageShape (Object message) =
      let role = case KM.lookup "role" message of
            Just (String value) -> value
            _ -> "?"
          content = case KM.lookup "content" message of
            Just (String value) -> "text(" <> tshow (T.length value) <> ")"
            Just (Array blocks) -> T.intercalate "+" (map blockShape (toList blocks))
            Just Null -> "null"
            Nothing -> "absent"
            _ -> "?"
          toolCalls = case KM.lookup "tool_calls" message of
            Just (Array values) -> ",tool_calls(" <> tshow (length values) <> ")"
            _ -> ""
          reasoning =
            if KM.member "reasoning_content" message || KM.member "reasoning" message
              then ",reasoning"
              else ""
       in role <> ": " <> content <> toolCalls <> reasoning
    messageShape _ = "?"

    blockShape (Object block) = case KM.lookup "type" block of
      Just (String blockType)
        | blockType == "text",
          Just (String value) <- KM.lookup "text" block ->
            "text(" <> tshow (T.length value) <> ")"
        | otherwise -> blockType <> "(" <> urlInfo (KM.lookup (Key.fromText blockType) block) <> ")"
      _ -> "?"
    blockShape _ = "?"

    urlInfo (Just (Object value))
      | Just (String urlValue) <- KM.lookup "url" value =
          case T.stripPrefix "data:" urlValue of
            Just rest ->
              let (mime, payload) = T.breakOn ";base64," rest
               in "data:" <> mime <> ";" <> tshow (max 0 (T.length payload - 8)) <> "-b64-chars"
            Nothing -> T.take 60 urlValue
    urlInfo _ = "?"

maxBufferedResponseBytes :: Int
maxBufferedResponseBytes = 16 * 1024 * 1024

statusPreviewBytes :: Int
statusPreviewBytes = 500
