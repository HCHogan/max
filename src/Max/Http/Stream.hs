-- | HTTP SSE transport using the shared HttpRuntime for response lifetime.
-- Fold frames and emit growing assistant text. Retry eligible transport/status
-- failures only before text or tool calls arrive; after that, return the partial
-- result without replaying already-observable work.
module Max.Http.Stream
  ( streamPost,
    StreamOutcome (..),
    maxStreamBytes,
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (waitSTM, withAsync)
import Control.Concurrent.STM (atomically, newTBQueueIO, orElse, readTBQueue, writeTBQueue)
import Control.Monad (join, when)
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
                  join
                    <$> withStreamingResponse
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

    readLoop updates progress bodyReader = loop maxStreamBytes "" emptyAcc
      where
        loop remaining buf acc = do
          chunk <- HTTP.brRead bodyReader
          if BS.null chunk
            then pure (Right acc)
            else
              if BS.length chunk > remaining
                then pure (Left (ResponseBodyLimitExceeded maxStreamBytes))
                else do
                  let (frames, rest) = sseFrames (buf <> chunk)
                      acc' = foldl' (flip step) acc frames
                  writeIORef progress acc'
                  when (acc'.saText /= acc.saText) (atomically (writeTBQueue updates acc'))
                  -- Usage may follow the terminal frame in another body chunk.
                  loop (remaining - BS.length chunk) rest acc'

-- | Cap all received SSE bytes, including unfinished frames, reasoning and
-- tool arguments. This bounds the cumulative provider state and queued views.
maxStreamBytes :: Int
maxStreamBytes = 16 * 1024 * 1024

statusPreviewBytes :: Int
statusPreviewBytes = 2000
