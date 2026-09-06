{-# LANGUAGE TypeFamilies #-}

-- |
-- Multi-profile OpenAI-compatible chat client.  Callers pick a profile name
-- per completion; the production interpreter resolves its private transport
-- configuration through 'ModelCatalog'.  Public profile discovery and
-- capability queries live in "Max.ModelCatalog", outside this effect.
--
-- The 'LLM' effect is intentionally raw: one HTTP request in, one
-- response out, no looping.  The agent loop lives in
-- "Max.Effects.Agent".
--
-- == Streaming
--
-- 'chatStreaming' is the same call with a sink for the assistant text as
-- it arrives.  Whether it actually streams is a per-profile switch: with
-- it off the sink is never called and the call behaves exactly like
-- 'chat', so callers need no branch.  The SSE framing and delta
-- reducers live in "Max.LLM.Stream" (pure, tested against recorded wire
-- bytes) and the incremental POST in "Max.Http.Stream".
--
-- == Tools
--
-- 'chat' accepts a list of 'ToolSpec's (name + JSON schema + free-text
-- description).  When non-empty the request adds @tools@ and
-- @tool_choice: "auto"@; the model can then return either text
-- ('ContentResp') or function calls ('ToolCallsResp').
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
    runRuntimeLLM,
    withLLMConfigGeneration,
    LLMInterpreter (..),
    runLLMWith,
    chat,
    chatStreaming,

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
import Effectful
import Effectful.Dispatch.Dynamic (interpose, interpret, localSeqUnlift, send)
import Effectful.Log
import GHC.Clock (getMonotonicTimeNSec)
import Max.Http.Json (defaultRetryDelaysSecs, replyRetryDelaysSecs)
import Max.HttpRuntime (HttpRuntime)
import Max.LLM.Admission (Admission, newAdmission, priorityForSource, withAdmission)
import Max.LLM.CallContext
import Max.LLM.Configuration (configureCallProfile, resolveCallCatalog)
import Max.LLM.Failure
import Max.LLM.Observability (logChatRequest, recordChatResult)
import Max.LLM.Protocol
import Max.LLM.Transport (callChat, callChatStream, interruptionMarker)
import Max.LLM.Types
import Max.ModelCatalog (ModelCatalog)
import Max.ModelCatalog.Internal (LLMProfile (..))
import Max.RuntimeConfig (ConfigGeneration, RuntimeConfigStore)
import Max.Tool.Types (ToolSpec (..))

data LLM :: Effect where
  Chat :: ChatCtx -> Text -> [ChatMessage] -> [ToolSpec] -> LLM m (Either LLMFailure ChatResponse)
  -- | 'Chat', but the assistant text is handed over as it arrives.
  --
  -- The sink receives the text /so far/, not the delta: the accumulator
  -- already holds the whole thing, and a caller deciding \"is a
  -- paragraph finished\" has to look at the accumulation anyway.  It
  -- runs outside the network timeout, with a bounded queue backpressuring the socket
  -- — which is what we want, since it is sending QQ messages.
  --
  -- Falls back to a plain 'Chat' when the profile has streaming off;
  -- the sink is then simply never called, so callers need no branch.
  ChatStreaming ::
    ChatCtx ->
    Text ->
    [ChatMessage] ->
    [ToolSpec] ->
    (Text -> m ()) ->
    LLM m (Either LLMFailure ChatResponse)

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
runLLM runtime usageWriter callWriter reg = runLLMResolving runtime usageWriter callWriter (const (pure (Right reg)))

-- | Production interpreter: an agent call resolves the generation leased by
-- its dispatch, while a background call resolves the current generation at
-- call start.  A leased generation remains in the store until the turn's outer
-- finalizer releases it.
runRuntimeLLM ::
  (Log :> es, IOE :> es) =>
  HttpRuntime ->
  UsageWriter ->
  CallWriter ->
  RuntimeConfigStore ->
  Eff (LLM : es) a ->
  Eff es a
runRuntimeLLM runtime usageWriter callWriter store =
  runLLMResolving runtime usageWriter callWriter (resolveCallCatalog store)

-- | Supply one worker generation to background calls which do not already
-- carry a dispatch lease.  Explicit turn generations always win.  This
-- interposer sits inside the generation worker scope, preventing an old worker
-- in the retirement overlap from combining its old inputs with the newly
-- published model catalog.
withLLMConfigGeneration ::
  (LLM :> es) =>
  ConfigGeneration ->
  Eff es a ->
  Eff es a
withLLMConfigGeneration generation = interpose $ \localEnv -> \case
  Chat ctx profile messages tools ->
    send (Chat (stamp ctx) profile messages tools)
  ChatStreaming ctx profile messages tools sink ->
    localSeqUnlift localEnv $ \unlift ->
      send (ChatStreaming (stamp ctx) profile messages tools (unlift . sink))
  where
    stamp ctx =
      ctx
        { ccConfigGeneration =
            case ctx.ccConfigGeneration of
              Just existing -> Just existing
              Nothing -> Just generation
        }

runLLMResolving ::
  (Log :> es, IOE :> es) =>
  HttpRuntime ->
  UsageWriter ->
  CallWriter ->
  (ChatCtx -> IO (Either LLMFailure ModelCatalog)) ->
  Eff (LLM : es) a ->
  Eff es a
runLLMResolving runtime usageWriter callWriter resolve action = do
  admission <- liftIO (newAdmission 50 10)
  interpret
    ( \localEnv -> \case
        Chat ctx name msgs tools -> do
          reg <- liftIO (resolve ctx)
          either (pure . Left) (\catalog -> runOneChat admission runtime usageWriter callWriter catalog ctx name msgs tools Nothing) reg
        ChatStreaming ctx name msgs tools sink ->
          -- The sink sends messages, so it is 'Eff', not IO; unlifting it
          -- here is what lets the transport call back into the caller's
          -- effect stack.  Sequential unlift is right: the read loop is
          -- single-threaded and calls the sink one frame at a time.
          localSeqUnlift localEnv $ \unlift -> do
            reg <- liftIO (resolve ctx)
            either (pure . Left) (\catalog -> runOneChat admission runtime usageWriter callWriter catalog ctx name msgs tools (Just (unlift . sink))) reg
    )
    action

-- | One chat call, shared by the streaming and non-streaming
-- operations.  A 'Just' sink means \"stream if the profile allows it\";
-- 'Nothing', or a profile with @stream = false@, takes the ordinary
-- request-response path.
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
  Eff es (Either LLMFailure ChatResponse)
runOneChat admission runtime usageWriter callWriter reg ctx name msgs tools mSink = case configureCallProfile reg ctx name of
  Nothing -> do
    logAttention "llm: unknown profile" $ object ["profile" .= name]
    pure $ Left (LLMUnknownProfile name)
  Just cfg -> do
    let bufferedRetryDelays = fromMaybe defaultRetryDelaysSecs ctx.ccBufferedRetryDelaysSeconds
        streaming = cfg.stream && isJust mSink
    logChatRequest name cfg streaming (length msgs) (length tools) (length (if streaming then replyRetryDelaysSecs else bufferedRetryDelays))
    started <- liftIO getMonotonicTimeNSec
    result <- withAdmission admission cfg.baseUrl (priorityForSource ctx.ccSource) $ case mSink of
      Just sink | cfg.stream -> callChatStream runtime cfg msgs tools sink
      _ -> callChat runtime bufferedRetryDelays cfg msgs tools
    finished <- liftIO getMonotonicTimeNSec
    recordChatResult usageWriter callWriter ctx name cfg streaming msgs tools (fromIntegral ((finished - started) `div` 1_000_000)) result
    pure (fst <$> result)

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
