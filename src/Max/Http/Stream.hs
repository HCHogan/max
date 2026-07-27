-- |
-- The transport half of streaming completions: POST a request and read
-- the response body as it arrives, folding SSE frames into a
-- 'StreamAcc' and calling back whenever the assistant text grows.
--
-- Separate from "Max.Wreq" because wreq has no incremental read — it
-- hands you the whole body, which is exactly what streaming exists to
-- avoid.  So this drops to @http-client@'s 'withResponse' \/ 'brRead'
-- and re-implements the pieces "Max.Wreq" gave us for free: manager
-- settings, timeout, non-2xx handling, retries.
--
-- == Retries are not free here
--
-- 'Max.Wreq.postAndParseRetrying' can replay any failed POST because
-- nothing was observable until it succeeded.  A streamed call has
-- already sent messages to the group by the time it fails, and
-- replaying would say them twice.  So 'streamPost' retries only while
-- nothing has arrived — once there is any assistant text the failure is
-- returned with whatever was accumulated, and the caller decides what
-- to do with a half-written reply.
--
-- And only when the failure looks transient: transport errors,
-- timeouts, empty streams, and the statuses
-- 'Max.Wreq.retryableStatusBody' accepts (408\/429\/5xx, plus
-- relay-wrapped 4xx that blame an upstream).  A genuine bad request
-- fails once and fails identically forever — with the reply path's
-- schedule now stretching into minutes, replaying one would turn a
-- fast, diagnosable 400 into a three-minute stall before the same 400.
module Max.Http.Stream
  ( streamPost,
    StreamOutcome (..),
  )
where

import Control.Concurrent (threadDelay)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Control.Monad (when)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Effectful
import Effectful.Log
import Max.LLM.Stream (StreamAcc (..), emptyAcc, sseFrames)
import Max.Util (trySyncIO)
import Max.Wreq (retryableStatusBody)
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Network.HTTP.Types.Header (Header)
import Network.HTTP.Types.Status (statusCode)
import System.Timeout (timeout)

-- | How a streamed call ended.
data StreamOutcome
  = -- | The provider signalled a clean end ('saDone').
    StreamComplete !StreamAcc
  | -- | The body stopped early: socket closed, timed out, or the
    -- connection died mid-message.  The accumulator holds everything
    -- that did arrive — possibly a half-written sentence the group has
    -- already seen.  The 'Text' says what went wrong.
    StreamTruncated !StreamAcc !Text
  | -- | Nothing usable arrived: non-2xx, transport error before the
    -- first byte, or a body with no assistant text at all.  Safe to
    -- treat as an ordinary failed call.
    StreamFailed !Text
  deriving stock (Show)

-- | POST @body@ and fold the SSE response as it arrives.
--
-- @onGrow@ fires after any frame that extended 'saText', with the
-- accumulator so far.  It is called on the request thread, so a slow
-- callback backpressures the read loop — which is what we want: sending
-- a QQ message must not race ahead of the socket.
streamPost ::
  (Log :> es, IOE :> es) =>
  -- | Seconds to wait before each retry; length = max retries.  Only
  -- consulted while nothing has arrived yet.
  [Int] ->
  -- | Timeout for the whole stream, seconds.
  Int ->
  [Header] ->
  String -> -- url
  ByteString -> -- request body
  -- | One SSE payload folded into the accumulator
  -- ('Max.LLM.Stream.stepOpenAI' or @stepAnthropic@).
  (ByteString -> StreamAcc -> StreamAcc) ->
  -- | Called when the assistant text grew.
  (StreamAcc -> Eff es ()) ->
  Eff es StreamOutcome
streamPost delays secs hdrs url body step onGrow = go delays
  where
    go remaining = do
      (out, retryOk) <- attempt
      case out of
        StreamFailed err
          | retryOk, (d : rest) <- remaining -> do
              -- Only reachable when nothing arrived: any outcome with
              -- text comes back Truncated, never Failed.
              logAttention "stream: retrying" $
                object ["url" .= T.pack url, "delay_s" .= d, "error" .= err]
              liftIO (threadDelay (d * 1_000_000))
              go rest
        _ -> pure out

    attempt = do
      -- The accumulator lives outside the IO action so a connection
      -- that dies mid-message doesn't take the partial reply with it —
      -- that fragment is what the interruption marker gets appended to,
      -- and it is also how we tell a retryable failure from one that
      -- has already said something.
      progress <- liftIO (newIORef emptyAcc)
      res <- withRunInIO $ \run ->
        -- The wall clock covers the callbacks too, not just the socket:
        -- @onGrow@ sends QQ messages, so a long answer spends real time
        -- in here.  That is the intended shape — better one bound on
        -- "how long this call may take" than a separate one per read
        -- that a slow group could never trip.
        timeout (secs * 1_000_000) . trySyncIO $ do
          mgr <- HTTP.newManager settings
          req0 <- HTTP.parseRequest url
          let req =
                req0
                  { HTTP.method = "POST",
                    HTTP.requestHeaders = hdrs,
                    HTTP.requestBody = HTTP.RequestBodyBS body,
                    HTTP.responseTimeout =
                      HTTP.responseTimeoutMicro (secs * 1_000_000)
                  }
          HTTP.withResponse req mgr $ \resp -> do
            let code = statusCode (HTTP.responseStatus resp)
            if code >= 400
              then do
                preview <- HTTP.brReadSome (HTTP.responseBody resp) 2000
                pure (Left (code, T.take 500 (TE.decodeUtf8Lenient (LBS.toStrict preview))))
              else Right <$> readLoop run progress (HTTP.responseBody resp)
      soFar <- liftIO (readIORef progress)
      pure $ case res of
        Nothing -> stalled soFar "stream timed out"
        Just (Left e) -> stalled soFar ("http: " <> T.pack (show e))
        Just (Right (Left (code, rbody))) ->
          ( StreamFailed ("HTTP " <> T.pack (show code) <> ": " <> rbody),
            retryableStatusBody code rbody
          )
        Just (Right (Right acc))
          | acc.saDone -> (StreamComplete acc, False)
          | T.null acc.saText && null acc.saCalls ->
              (StreamFailed "stream ended with no content", True)
          | otherwise -> (StreamTruncated acc "stream ended without a terminal frame", False)

    -- A connection that died before producing anything is
    -- indistinguishable from an ordinary failed POST, so it stays
    -- retryable.  Once there is text, replaying would say it twice.
    stalled acc err
      | T.null acc.saText && null acc.saCalls = (StreamFailed err, True)
      | otherwise = (StreamTruncated acc err, False)

    readLoop run progress bodyReader = loop "" emptyAcc
      where
        loop buf acc = do
          chunk <- HTTP.brRead bodyReader
          if BS.null chunk
            then pure acc
            else do
              let (frames, rest) = sseFrames (buf <> chunk)
                  acc' = foldl (flip step) acc frames
              writeIORef progress acc'
              when (acc'.saText /= acc.saText) (run (onGrow acc'))
              loop rest acc'

    settings =
      tlsManagerSettings
        { HTTP.managerResponseTimeout =
            HTTP.responseTimeoutMicro (secs * 1_000_000)
        }
