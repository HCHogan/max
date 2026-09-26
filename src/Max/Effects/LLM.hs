{-# LANGUAGE TypeFamilies #-}

-- | One model completion per call; the Agent interpreter owns the loop.
-- ModelCatalog resolves named profiles and exposes their public capabilities.
-- chatStreaming supplies accumulated assistant text when the profile enables
-- streaming, otherwise behaves as chat without calling the sink. Pure codecs
-- live in Max.LLM.Stream; HTTP streaming lives in Max.Http.Stream.
module Max.Effects.LLM
  ( LLM,

    -- * Messages
    ChatMessage (..),
    ContentBlock (..),
    ToolCall (..),

    -- * Tool descriptions for the wire
    ToolSpec (..),

    -- * Response
    ChatResponse (..),
    TokenUsage (..),
    TokenPrices (..),
    CallCost (..),
    priceUsage,
    LLMFailure (..),
    renderLLMFailure,

    -- * Call attribution
    ChatCtx (..),
    UsageWriter,
    CallWriter,
    CallRecord (..),
    requestBodyFor,

    -- * Effect operations
    runLLM,
    LLMInterpreter (..),
    runLLMWith,
    chat,
    chatStreaming,
    chatMeasured,

    -- * Exposed for tests
    parseResponseOpenAI,
    parseResponseAnthropic,
    parseResponseResponses,
    responsesFields,
    rebuildResponses,
    rebuildOpenAI,
    rebuildAnthropic,
    stripLeadingThink,
    interruptionMarker,
  )
where

import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Effectful
import Effectful.Dispatch.Dynamic (interpret, localSeqUnlift, send)
import Effectful.Log
import GHC.Clock (getMonotonicTimeNSec)
import Max.Http.Json (defaultRetryDelaysSecs, replyRetryDelaysSecs)
import Max.HttpRuntime (HttpRuntime)
import Max.LLM.Admission (Admission, newAdmission, priorityForSource, withAdmission)
import Max.LLM.CallContext
import Max.LLM.Configuration (configureCallProfile)
import Max.LLM.Failure
import Max.LLM.Observability (logChatRequest, recordChatResult)
import Max.LLM.Protocol
import Max.LLM.Transport (callChat, callChatStream, interruptionMarker)
import Max.LLM.Types
import Max.ModelCatalog (ModelCatalog)
import Max.ModelCatalog.Internal (LLMProfile (..))
import Max.Tool.Types (ToolSpec (..))

data LLM :: Effect where
  Chat :: ChatCtx -> Text -> [ChatMessage] -> [ToolSpec] -> LLM m (Either LLMFailure ChatResponse)
  -- | Chat with accumulated assistant text delivered to the sink.
  -- The sink runs outside the network timeout; a bounded queue backpressures the
  -- socket. Profiles with streaming disabled do not invoke the sink.
  ChatStreaming ::
    ChatCtx ->
    Text ->
    [ChatMessage] ->
    [ToolSpec] ->
    (Text -> m ()) ->
    LLM m (Either LLMFailure ChatResponse)
  -- | The same call plus provider usage, scoped to this invocation (never a
  -- shared last-usage slot that concurrent turns could overwrite).
  ChatMeasured :: ChatCtx -> Text -> [ChatMessage] -> [ToolSpec] -> Maybe (Text -> m ()) -> LLM m (Either LLMFailure (ChatResponse, Maybe TokenUsage))

type instance DispatchOf LLM = Dynamic

-- | A first-class interpreter record for tests and alternate in-process
-- backends.  'liChat' receives 'Nothing' for a buffered call and a sink for a
-- streaming call; the sink has already been safely unlifted into @es@.
data LLMInterpreter es = LLMInterpreter
  { liChat ::
      ChatCtx ->
      Text ->
      [ChatMessage] ->
      [ToolSpec] ->
      Maybe (Text -> Eff es ()) ->
      Eff es (Either LLMFailure ChatResponse)
  }

-- | Install a supplied interpreter without HTTP, credentials, or a model
-- registry.  This is the seam used by full-loop Agent tests: it can inspect
-- the exact conversation, drive streaming frames, and return tool calls.
runLLMWith ::
  LLMInterpreter es ->
  Eff (LLM : es) a ->
  Eff es a
runLLMWith backend = interpret $ \localEnv -> \case
  ChatMeasured ctx profile msgs tools sink ->
    localSeqUnlift localEnv $ \unlift ->
      fmap (,Nothing) <$> backend.liChat ctx profile msgs tools (fmap (unlift .) sink)
  Chat ctx profile msgs tools ->
    backend.liChat ctx profile msgs tools Nothing
  ChatStreaming ctx profile msgs tools sink ->
    localSeqUnlift localEnv $ \unlift ->
      backend.liChat ctx profile msgs tools (Just (unlift . sink))

-- | Per-profile timeout is enforced twice: the request's http-client
-- 'HTTP.responseTimeout' is set to @timeoutSeconds@ inside
-- 'postAndParse' (otherwise the built-in 30s default kills
-- any generation slower than that — non-streaming endpoints send
-- nothing until the completion is done), and a 'System.Timeout.timeout'
-- wraps the whole call as the wallclock belt-and-braces.
runLLM ::
  (Log :> es, IOE :> es) =>
  HttpRuntime ->
  UsageWriter ->
  CallWriter ->
  ModelCatalog ->
  Eff (LLM : es) a ->
  Eff es a
runLLM runtime usageWriter callWriter catalog action = do
  admission <- liftIO (newAdmission 50 10)
  interpret
    ( \localEnv -> \case
        ChatMeasured ctx name msgs tools sink ->
          localSeqUnlift localEnv $ \unlift ->
            runOneChat admission runtime usageWriter callWriter catalog ctx name msgs tools (fmap (unlift .) sink)
        Chat ctx name msgs tools ->
          fmap fst <$> runOneChat admission runtime usageWriter callWriter catalog ctx name msgs tools Nothing
        ChatStreaming ctx name msgs tools sink ->
          localSeqUnlift localEnv $ \unlift ->
            fmap fst <$> runOneChat admission runtime usageWriter callWriter catalog ctx name msgs tools (Just (unlift . sink))
    )
    action

runOneChat ::
  (Log :> es, IOE :> es) =>
  Admission ->
  HttpRuntime ->
  UsageWriter ->
  CallWriter ->
  ModelCatalog ->
  ChatCtx ->
  Text ->
  [ChatMessage] ->
  [ToolSpec] ->
  Maybe (Text -> Eff es ()) ->
  Eff es (Either LLMFailure (ChatResponse, Maybe TokenUsage))
runOneChat admission runtime usageWriter callWriter reg ctx name msgs tools mSink = case configureCallProfile reg ctx name of
  Nothing -> do
    logAttention "llm: unknown profile" $ object ["profile" .= name]
    pure $ Left (LLMUnknownProfile name)
  Just cfg -> do
    result <- attempt cfg
    case (result, configureCallProfile reg ctx {ccPromptTokens = Nothing} name) of
      -- The prompt estimate can undershoot. When the server refuses the
      -- adaptive completion limit, ask once more with the planning reserve.
      (Left failure, Just reserve)
        | reserve.maxTokens < cfg.maxTokens && windowRejected failure -> do
            logAttention "llm: adaptive completion limit rejected; retrying with the reserve" $
              object ["profile" .= name, "max_tokens" .= cfg.maxTokens, "reserve" .= reserve.maxTokens]
            attempt reserve
      _ -> pure result
  where
    windowRejected failure =
      let detail = T.toLower (renderLLMFailure failure)
       in any (`T.isInfixOf` detail) ["context length", "max_tokens", "max_completion_tokens", "max_output_tokens"]
    attempt cfg = do
      let bufferedRetryDelays = fromMaybe defaultRetryDelaysSecs ctx.ccBufferedRetryDelaysSeconds
          streaming = cfg.stream && isJust mSink
      logChatRequest name cfg streaming (length msgs) (length tools) (length (if streaming then replyRetryDelaysSecs else bufferedRetryDelays))
      started <- liftIO getMonotonicTimeNSec
      raw <- withAdmission admission cfg.baseUrl (priorityForSource ctx.ccSource) $ case mSink of
        Just sink | cfg.stream -> callChatStream runtime cfg msgs tools sink
        _ -> callChat runtime bufferedRetryDelays cfg msgs tools
      finished <- liftIO getMonotonicTimeNSec
      -- Cost is priced here, once, so every observer books the same figure.
      let priced = fmap (fmap (fmap (\usage -> usage {usageCost = (`priceUsage` usage) <$> cfg.prices}))) raw
      recordChatResult usageWriter callWriter ctx name cfg streaming msgs tools (fromIntegral ((finished - started) `div` 1_000_000)) priced
      pure priced

chat ::
  (LLM :> es) =>
  ChatCtx ->
  Text -> -- profile name
  [ChatMessage] ->
  [ToolSpec] ->
  Eff es (Either LLMFailure ChatResponse)
chat ctx name msgs tools =
  send (Chat ctx name msgs tools)

-- | 'chat' with a sink for the assistant text as it streams in.  See
-- 'ChatStreaming'.
chatStreaming ::
  (LLM :> es) =>
  ChatCtx ->
  Text ->
  [ChatMessage] ->
  [ToolSpec] ->
  (Text -> Eff es ()) ->
  Eff es (Either LLMFailure ChatResponse)
chatStreaming ctx name msgs tools sink =
  send (ChatStreaming ctx name msgs tools sink)

-- | Invocation-local usage for working-context accounting.
chatMeasured :: (LLM :> es) => ChatCtx -> Text -> [ChatMessage] -> [ToolSpec] -> Maybe (Text -> Eff es ()) -> Eff es (Either LLMFailure (ChatResponse, Maybe TokenUsage))
chatMeasured ctx name messages specs sink = send (ChatMeasured ctx name messages specs sink)
