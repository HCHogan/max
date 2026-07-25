-- |
-- Shared JSON-POST transport for the wreq-based API clients (the
-- OpenAI/Anthropic chat calls in "Max.Effects.LLM", the Tavily call
-- in "Max.Tools.Search").
module Max.Wreq
  ( postAndParse,
    postAndParseRetrying,
    defaultRetryDelaysSecs,
    -- * Exposed for tests
    retryableStatus,
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException)
import Control.Lens ((&), (.~), (?~), (^.))
import Data.Aeson (Value (..), decode, eitherDecode)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (Parser, parseEither)
import Data.ByteString qualified as BS
import Data.Foldable (toList)
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

-- | Backoff schedule the LLM chat calls pass to
-- 'postAndParseRetrying': two retries, a short wait for transient
-- hiccups then a longer one for rate-limit windows.
defaultRetryDelaysSecs :: [Int]
defaultRetryDelaysSecs = [2, 8]

-- | Why one POST attempt failed, split by whether replaying the same
-- request could plausibly succeed.
data Failure
  = FailTimeout
  | FailTransport !Text
  | -- | Non-2xx status + truncated response body.
    FailStatus !Int !Text
  | -- | The response arrived but wasn't the JSON we wanted; a replay
    -- would get the same confusion back.
    FailDecode !Text

renderFailure :: Failure -> Text
renderFailure = \case
  FailTimeout -> "request timed out"
  FailTransport t -> "http: " <> t
  FailStatus code body -> "HTTP " <> T.pack (show code) <> ": " <> body
  FailDecode t -> t

retryableFailure :: Failure -> Bool
retryableFailure = \case
  FailTimeout -> True
  FailTransport _ -> True
  FailStatus code _ -> retryableStatus code
  FailDecode _ -> False

-- | Statuses worth a retry: timeout-ish and rate-limit-ish (408/429)
-- plus anything server-side.  Other 4xx mean our own request is
-- wrong — replaying it unchanged can't help.
retryableStatus :: Int -> Bool
retryableStatus code = code == 408 || code == 429 || code >= 500

-- | POST @body@ to @url@, parse the JSON response with @parser@.
-- One shot, no retries — the interactive callers (search) prefer a
-- fast error over a stalled reply.
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
postAndParse = postAndParseRetrying []

-- | 'postAndParse' with a retry schedule: on a retryable failure
-- (timeout, transport error, 408\/429\/5xx) wait the next delay and
-- re-POST the same body; give up when the schedule is exhausted.
-- Chat completions are idempotent, so the replay is safe.
postAndParseRetrying ::
  (W.Wreq :> es, Log :> es, IOE :> es) =>
  -- | Seconds to wait before each retry; length = max retries.
  [Int] ->
  -- | Timeout per attempt, seconds.
  Int ->
  Wreq.Options ->
  String -> -- url
  BS.ByteString -> -- body
  (Value -> Parser a) ->
  Eff es (Either Text a)
postAndParseRetrying delays secs opts url body parser = go delays
  where
    mgrSettings =
      tlsManagerSettings
        { HTTP.managerResponseTimeout =
            HTTP.responseTimeoutMicro (secs * 1_000_000)
        }
    opts' =
      opts
        & WL.manager .~ Left mgrSettings
        & WL.checkResponse ?~ (\_ _ -> pure ())

    go remaining = do
      r <- attempt
      case r of
        Left f
          | retryableFailure f,
            (d : rest) <- remaining -> do
              logAttention "http: retrying" $
                object
                  [ "url" .= T.pack url,
                    "delay_s" .= d,
                    "error" .= renderFailure f
                  ]
              liftIO (threadDelay (d * 1_000_000))
              go rest
        _ -> pure (either (Left . renderFailure) Right r)

    attempt = do
      res <- withRunInIO $ \run ->
        timeout (secs * 1_000_000) $
          trySyncIO (run (W.postWith opts' url body))
      case res of
        Nothing -> pure (Left FailTimeout)
        Just (Left e) -> pure (Left (FailTransport (T.pack (show (e :: SomeException)))))
        Just (Right resp) -> do
          let code = statusCode (resp ^. WL.responseStatus)
              rbody = resp ^. WL.responseBody
          if code >= 400
            then do
              -- 4xx bodies like "invalid_request_error" are
              -- undiagnosable without seeing what we actually sent —
              -- log a (truncated) copy of the request alongside, plus
              -- a per-message structural digest: the first 4000 chars
              -- are usually all system prompt, while the poison
              -- (a data-URL block, a mangled assistant turn) hides in
              -- later messages the truncation never reaches.
              logAttention "http error request dump" $
                object $
                  [ "url" .= T.pack url,
                    "status" .= code,
                    "request_body" .= T.take 4000 (TE.decodeUtf8Lenient body)
                  ]
                    <> maybe [] (\s -> ["request_shape" .= s]) (requestShape body)
              pure $
                Left $
                  FailStatus code (T.take 500 (TE.decodeUtf8Lenient (LBS.toStrict rbody)))
            else
              let bodyPreview =
                    T.take 800 (TE.decodeUtf8Lenient (LBS.toStrict rbody))
               in pure $ case eitherDecode rbody of
                    Left e ->
                      Left (FailDecode ("parse: " <> T.pack e <> "\nbody: " <> bodyPreview))
                    Right v -> case parseEither parser v of
                      Left e ->
                        Left (FailDecode ("extract: " <> T.pack e <> "\nbody: " <> bodyPreview))
                      Right r -> Right r

-- | One line per message of a chat-completion request body: role,
-- content kind, block types with data-URL mime + base64 size, tool
-- calls, reasoning fields.  'Nothing' when the body isn't a
-- @{messages: [...]}@ object (e.g. the Tavily call).
requestShape :: BS.ByteString -> Maybe [Text]
requestShape b = do
  Object o <- decode (LBS.fromStrict b)
  Array msgs <- KM.lookup "messages" o
  pure (map msgShape (toList msgs))
  where
    tshow :: Show a => a -> Text
    tshow = T.pack . show

    msgShape (Object m) =
      let role = case KM.lookup "role" m of
            Just (String r) -> r
            _ -> "?"
          content = case KM.lookup "content" m of
            Just (String t) -> "text(" <> tshow (T.length t) <> ")"
            Just (Array bs) -> T.intercalate "+" (map blockShape (toList bs))
            Just Null -> "null"
            Nothing -> "absent"
            _ -> "?"
          tcs = case KM.lookup "tool_calls" m of
            Just (Array a) -> ",tool_calls(" <> tshow (length a) <> ")"
            _ -> ""
          rc =
            if KM.member "reasoning_content" m || KM.member "reasoning" m
              then ",reasoning"
              else ""
       in role <> ": " <> content <> tcs <> rc
    msgShape _ = "?"

    blockShape (Object blk) = case KM.lookup "type" blk of
      Just (String ty)
        | ty == "text",
          Just (String t) <- KM.lookup "text" blk ->
            "text(" <> tshow (T.length t) <> ")"
        | otherwise -> ty <> "(" <> urlInfo (KM.lookup (Key.fromText ty) blk) <> ")"
      _ -> "?"
    blockShape _ = "?"

    urlInfo (Just (Object u))
      | Just (String url) <- KM.lookup "url" u =
          case T.stripPrefix "data:" url of
            Just rest ->
              let (mime, payload) = T.breakOn ";base64," rest
               in "data:" <> mime <> ";" <> tshow (max 0 (T.length payload - 8)) <> "-b64-chars"
            Nothing -> T.take 60 url
    urlInfo _ = "?"
