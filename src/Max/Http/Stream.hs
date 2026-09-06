-- |
-- The transport half of streaming completions: POST a request and read
-- the response body as it arrives, folding SSE frames into a
-- 'StreamAcc' and calling back whenever the assistant text grows.
--
-- Request execution and response lifetime come from "Max.HttpRuntime";
-- this module owns only SSE folding and the domain-specific retry boundary.
--
-- == Retries are not free here
--
-- 'Max.Http.Json.postAndParseRetrying' can replay any failed POST because
-- nothing was observable until it succeeded.  A streamed call has
-- already sent messages to the group by the time it fails, and
-- replaying would say them twice.  So 'streamPost' retries only while
-- nothing has arrived — once there is any assistant text the failure is
-- returned with whatever was accumulated, and the caller decides what
-- to do with a half-written reply.
--
-- Retries are based on structured transport failures and HTTP statuses.
-- Once text or tool calls arrive, no automatic replay is permitted.
module Max.Http.Stream
  ( streamPost,
    StreamOutcome (..),
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (waitSTM, withAsync)
import Control.Concurrent.STM (atomically, newTBQueueIO, orElse, readTBQueue, writeTBQueue)
import Control.Monad (when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Text qualified as T
import Effectful
import Effectful.Log
import Max.Http.Failure (ResponseFailure (..), retryableResponseFailure)
import Max.HttpRuntime
  ( HttpPool (StandardPool),
    HttpRuntime,
    TransportFailure (..),
    parseRequestEither,
    withStreamingResponse,
  )
import Max.LLM.Stream (StreamAcc (..), emptyAcc, sseFrames)
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Types.Header (Header)
import System.Timeout (timeout)

-- | How a streamed call ended.
data StreamOutcome
  = -- | The provider signalled a clean end ('saDone').
    StreamComplete !StreamAcc
  | -- | The body stopped early: socket closed, timed out, or the
    -- connection died mid-message.  The accumulator holds everything
    -- that did arrive — possibly a half-written sentence the group has
    -- already seen. The failure retains its structured cause.
    StreamTruncated !StreamAcc !ResponseFailure
  | -- | Nothing usable arrived: non-2xx, transport error before the
    -- first byte, or a body with no assistant text at all.  Safe to
    -- treat as an ordinary failed call.
    StreamFailed !ResponseFailure
  deriving stock (Show)

-- | POST @body@ and fold the SSE response as it arrives.
--
-- @onGrow@ fires after any frame that extended 'saText', with the
-- accumulator so far. A single-slot queue backpressures the reader while
-- publication runs on the caller thread, outside the network timeout.
streamPost ::
  (Log :> es, IOE :> es) =>
  HttpRuntime ->
  -- | Seconds to wait before each retry; length = max retries.  Only
  -- consulted while nothing has arrived yet.
  [Int] ->
  -- | Timeout for receiving the stream, seconds; publication is outside it.
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
streamPost runtime delays secs hdrs url body step onGrow = go delays
  where
    go remaining = do
      (out, retryOk) <- attempt
      case out of
        StreamFailed err
          | retryOk,
            (d : rest) <- remaining -> do
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
      result <- withRunInIO $ \run -> do
        updates <- newTBQueueIO 1
        -- A timeout must never interrupt publication between an outbox commit
        -- and its sent-prefix acknowledgement. Otherwise the final tail would
        -- publish that same text again. Caller cancellation still cancels both
        -- threads and propagates; it is never converted into a partial reply.
        let receive = timeout (secs * 1_000_000) $ do
              parseRequestEither url >>= \case
                Left failure -> pure (Left failure)
                Right request0 ->
                  withStreamingResponse
                    runtime
                    StandardPool
                    statusPreviewBytes
                    request0
                      { HTTP.method = "POST",
                        HTTP.requestHeaders = hdrs,
                        HTTP.requestBody = HTTP.RequestBodyBS body,
                        HTTP.responseTimeout =
                          HTTP.responseTimeoutMicro (secs * 1_000_000)
                      }
                    (\_ -> readLoop updates progress)
        withAsync receive $ \reader -> do
          let drain = do
                next <-
                  atomically $
                    (Left <$> readTBQueue updates) `orElse` (Right <$> waitSTM reader)
                case next of
                  Left acc -> run (onGrow acc) >> drain
                  Right outcome -> pure outcome
          drain
      soFar <- liftIO (readIORef progress)
      pure $ case result of
        Nothing -> stalled soFar (ResponseTransport ResponseTimeoutFailure)
        Just (Left failure) -> stalled soFar (ResponseTransport failure)
        Just (Right acc)
          | acc.saDone -> (StreamComplete acc, False)
          | T.null acc.saText && null acc.saCalls ->
              (StreamFailed ResponseEmptyStream, True)
          | otherwise -> (StreamTruncated acc ResponseMissingTerminal, False)

    -- A connection that died before producing anything is
    -- indistinguishable from an ordinary failed POST, so it stays
    -- retryable.  Once there is text, replaying would say it twice.
    stalled acc err
      | acc.saDone = (StreamComplete acc, False)
      | T.null acc.saText && null acc.saCalls = (StreamFailed err, retryableResponseFailure err)
      | otherwise = (StreamTruncated acc err, False)

    readLoop updates progress bodyReader = loop "" emptyAcc
      where
        loop buf acc = do
          chunk <- HTTP.brRead bodyReader
          if BS.null chunk
            then pure acc
            else do
              let (frames, rest) = sseFrames (buf <> chunk)
                  acc' = foldl (flip step) acc frames
              writeIORef progress acc'
              when (acc'.saText /= acc.saText) (atomically (writeTBQueue updates acc'))
              -- OpenAI usage may follow finish_reason in a later body chunk.
              -- Continue collecting it; a timeout after a terminal frame still
              -- returns the completed message via 'stalled'.
              loop rest acc'

statusPreviewBytes :: Int
statusPreviewBytes = 2000
