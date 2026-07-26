{-# LANGUAGE TypeFamilies #-}

-- |
-- Multi-profile OpenAI-compatible chat client.  The interpreter holds
-- a map of named 'LLMProfile's (each one has its own api_key,
-- base_url, model, etc.); callers pick which profile to use per call.
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
    LLMProfile (..),
    LLMRegistry (..),
    Protocol (..),
    parseProtocol,
    -- * Messages
    ChatMessage (..),
    ContentBlock (..),
    ToolCall (..),
    -- * Tool descriptions for the wire
    ToolSpec (..),
    -- * Response
    ChatResponse (..),
    TokenUsage (..),
    -- * Effect operations
    runLLM,
    chat,
    listProfiles,
    defaultProfile,
    isProfileMultimodal,
    isProfileHistoryTurns,
    chatStreaming,
    -- * Exposed for tests
    parseResponseOpenAI,
    parseResponseAnthropic,
    rebuildOpenAI,
    rebuildAnthropic,
    stripLeadingThink,
    interruptionMarker,
  )
where

import Control.Applicative ((<|>))
import Data.List (find)
import Data.Maybe (isJust)
import Control.Lens ((&), (.~))
import Data.Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (Pair, Parser, parseMaybe)
import Data.ByteString.Lazy qualified as LBS
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Vector qualified as V
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Effectful
import Effectful.Dispatch.Dynamic (interpret, localSeqUnlift, send)
import Effectful.Log
import Effectful.Wreq qualified as W
import Max.Http.Stream (StreamOutcome (..), streamPost)
import Max.LLM.Stream (StreamAcc (..), accToolCalls, stepAnthropic, stepOpenAI, PartialCall (..))
import Max.Wreq (defaultRetryDelaysSecs, postAndParseRetrying)
import Network.Wreq qualified as Wreq
import Network.Wreq.Lens qualified as WL

-- | Which wire format the endpoint speaks.  Picks URL suffix, auth
-- header shape, request body structure, and response parser.
data Protocol
  = -- | OpenAI / OpenAI-compatible: POST @{baseUrl}/chat/completions@
    -- with @Authorization: Bearer@.  Default — most LLM-as-a-service
    -- ships this.
    ProtocolOpenAI
  | -- | Native Anthropic Messages API: POST @{baseUrl}/v1/messages@
    -- with @x-api-key@ + @anthropic-version: 2023-06-01@.  Use this
    -- when the endpoint only exposes Anthropic format, OR when an
    -- OpenAI-compat proxy mangles tool-call shapes during translation
    -- (e.g. drops @function.name@) — going native skips the lossy
    -- translation layer.  Set 'baseUrl' to the API root (no @/v1@
    -- suffix); we append @/v1/messages@.
    ProtocolAnthropic
  deriving stock (Show, Eq)

-- | Parse a protocol name from config (TOML / env / CLI).
-- Case-insensitive.  Returns 'Nothing' for anything other than
-- @openai@ / @anthropic@.
parseProtocol :: Text -> Maybe Protocol
parseProtocol t = case T.toLower (T.strip t) of
  "openai" -> Just ProtocolOpenAI
  "anthropic" -> Just ProtocolAnthropic
  _ -> Nothing

-- | A single named LLM endpoint.  Materialized from one entry of the
-- @[[llm.profiles]]@ array in TOML.
data LLMProfile = LLMProfile
  { -- | OpenAI: e.g. @https://api.deepseek.com/v1@; we append @/chat/completions@.
    -- Anthropic: e.g. @https://api.anthropic.com@; we append @/v1/messages@.
    baseUrl :: !Text,
    apiKey :: !Text,
    -- | Model id; @deepseek-v4-flash@, @deepseek-v4-pro@, @gpt-4o-mini@,
    -- @claude-opus-4-6@, etc.
    model :: !Text,
    maxTokens :: !Int,
    -- | 'Nothing' = omit the field entirely (server default).  Some
    -- providers (kimi via opencode zen) reject any explicit value
    -- other than 1.0 with a generic 400, so only send when the user
    -- configured one.
    temperature :: !(Maybe Double),
    -- | HTTP timeout for one chat completion.  LLMs are slow, default 120.
    timeoutSeconds :: !Int,
    -- | Wire format spoken by the endpoint.  Default 'ProtocolOpenAI'.
    protocol :: !Protocol,
    -- | Whether the endpoint can handle multimodal (image) content
    -- blocks.  When 'True', 'Max.Prompt' embeds images from the
    -- trigger and recent context as inline image blocks (OpenAI
    -- @image_url@ / Anthropic @source:base64@); when 'False'
    -- (default), only text is sent and images stay as @[image]@
    -- markers.  Turn this on for Gemma 4 / GPT-4o / Claude vision
    -- endpoints; leave off for DeepSeek (text-only).
    multimodal :: !Bool,
    -- | Which prompt shape to build for this profile.  'False'
    -- (default) is the flat transcript: system + one user message, the
    -- whole conversation as @[HH:MM \<name\> #\<id\>]:@ lines.  'True'
    -- puts history back into real @user@\/@assistant@ turns.
    --
    -- The two shapes trade one hazard for the other and there is no
    -- way to reason your way to a winner, so it is a per-profile
    -- switch you can A\/B with @!model@.  Turns anchor style on the
    -- bot's own past output and make it structurally impossible to
    -- imitate the line prefix; flat removes the assistant slot a weak
    -- model treats as a pattern to continue (a real production
    -- incident), can't produce consecutive same-role messages, and is
    -- the only shape where the bot's own messages carry a quotable id.
    historyAsTurns :: !Bool,
    -- | Read the completion incrementally over SSE, so finished
    -- paragraphs can go out while the model is still writing.  Default
    -- 'True'.
    --
    -- Per-profile purely as an escape hatch: every provider ships its
    -- own SSE dialect (usage in a terminal frame or not at all,
    -- @[DONE]@ or a bare @finish_reason@, keep-alive comment lines),
    -- and when one misbehaves the fix should be a config edit rather
    -- than a deploy.  With it off the profile takes the ordinary
    -- request-response path and nothing about it changes.
    --
    -- Replaying the assistant turn is /not/ a reason to turn it off:
    -- both protocols are designed so a stream reconstructs the message
    -- (see 'rebuildOpenAI', 'rebuildAnthropic'), reasoning and thinking
    -- blocks included.
    stream :: !Bool
  }
  deriving stock (Show)

-- | The full profile registry.  'runLLM' takes one of these; downstream
-- code picks profiles by name.
data LLMRegistry = LLMRegistry
  { defaultName :: !Text,
    profiles :: !(Map Text LLMProfile)
  }
  deriving stock (Show)

-- | One block in a multimodal user message.  Maps directly to the
-- OpenAI multimodal content-block format that ollama / vLLM /
-- OpenRouter all speak.  Use 'TextBlock' for ordinary text;
-- 'ImageDataUrl' for an inline @data:image\/...;base64,...@ URL
-- (works without exposing a local HTTP server — the model fetches
-- nothing, it gets the bytes inline).
data ContentBlock
  = TextBlock !Text
  | -- | The carried 'Text' is the full @data:image\/png;base64,xxxx@
    -- URL.  External http(s) URLs would also work but we don't use
    -- them (QQ CDN needs auth headers we don't share with the LLM).
    ImageDataUrl !Text
  | -- | Inline video, as a @data:video\/mp4;base64,...@ URL.  Encoded
    -- with the de-facto OpenAI-compatible extension
    -- @{type: video_url, video_url: {url}}@ that natively-video models
    -- (Kimi K3, Qwen-VL, GLM-4V…) accept.  Anthropic's protocol has no
    -- video input; it degrades to a text marker there.
    VideoDataUrl !Text
  deriving stock (Show, Eq)

-- | A single message in the chat history.  Mirrors OpenAI's role
-- enum.  Sum-typed so we can keep tool turns first-class instead of
-- carrying optional fields around.
data ChatMessage
  = -- | @{ role: "system", content: ... }@
    MsgSystem !Text
  | -- | @{ role: "user", content: ... }@
    MsgUser !Text
  | -- | Multimodal user message.  Used only when the active LLM
    -- profile sets @multimodal = true@; otherwise build a 'MsgUser'
    -- with text markers like @[image]@ instead.  Wire format
    -- is the OpenAI content-block array
    -- (@content: [{type:text,...}, {type:image_url,...}, ...]@).
    MsgUserBlocks ![ContentBlock]
  | -- | Plain assistant text response.  Any 'reasoning_content' from
    -- the original response is dropped — per DeepSeek docs it's not
    -- needed in subsequent turns when no tool call happened.
    MsgAssistant !Text
  | -- | Assistant chose to call one or more tools.  Carries the
    -- provider's assistant message verbatim (the raw 'Value' exactly
    -- as received), because thinking output must round-trip to the
    -- API in the *next* request within the same agent dispatch in
    -- whatever field/structure the provider used
    -- (@reasoning_content@, @reasoning_details@, thinking blocks, …)
    -- — DeepSeek returns 400 when it's missing.  The '[ToolCall]'
    -- list is our parsed view of the same message, used to execute
    -- the calls.  Protocol-consistent within one dispatch: the raw
    -- shape matches the profile that produced it.
    MsgAssistantToolCalls !Value ![ToolCall]
  | -- | Tool result reply: @{ role: "tool", tool_call_id: ..., content: ... }@.
    -- 'content' is freeform text (typically a JSON-encoded result).
    MsgTool !Text !Text
  deriving stock (Show)

-- | One tool invocation as returned by the model (or recorded in
-- history for replay).  @arguments@ is parsed JSON in our types; the
-- wire format stringifies it (OpenAI's choice).
data ToolCall = ToolCall
  { callId :: !Text,
    callName :: !Text,
    callArguments :: !Value
  }
  deriving stock (Show)

-- | Description of a tool we expose to the model.  The 'specSchema'
-- is the JSON Schema for the tool's arguments object.
data ToolSpec = ToolSpec
  { specName :: !Text,
    specDescription :: !Text,
    specSchema :: !Value
  }
  deriving stock (Show)

-- | What the model decided this turn.
data ChatResponse
  = -- | A plain text answer.  The loop is done.
    ContentResp !Text
  | -- | The model wants to call one or more tools.  Caller executes
    -- them and re-invokes 'chat' with the results appended.  The
    -- first field is the provider's assistant message verbatim; build
    -- the follow-up 'MsgAssistantToolCalls' from it so any thinking
    -- output replays to the API exactly as it came in (providers 400
    -- when their reasoning fields go missing or change shape).
    -- The 'Text' is whatever the model said alongside the calls —
    -- both protocols allow text and tool calls in one assistant
    -- message, and Claude narrates that way constantly.  Empty when
    -- the model went straight to the call.
    ToolCallsResp !Value !Text ![ToolCall]
  deriving stock (Show)

-- | Provider-reported token usage for one completion.  Logged in the
-- interpreter (never returned to callers), so journalctl alone is
-- enough to reconstruct token spend per profile.
data TokenUsage = TokenUsage
  { usagePrompt :: !Int,
    usageCompletion :: !Int,
    -- | Prompt tokens served from the provider's prefix cache, when
    -- reported (DeepSeek @prompt_cache_hit_tokens@, OpenAI
    -- @prompt_tokens_details.cached_tokens@, Anthropic
    -- @cache_read_input_tokens@).  Cache hits bill at a steep
    -- discount, so cost math needs the split.
    usageCachedPrompt :: !(Maybe Int)
  }
  deriving stock (Show, Eq)

--------------------------------------------------------------------------------
-- JSON.

instance ToJSON ContentBlock where
  toJSON = \case
    TextBlock t -> object ["type" .= ("text" :: Text), "text" .= t]
    VideoDataUrl url ->
      object
        [ "type" .= ("video_url" :: Text),
          "video_url" .= object ["url" .= url]
        ]
    ImageDataUrl url ->
      object
        [ "type" .= ("image_url" :: Text),
          "image_url" .= object ["url" .= url]
        ]

instance ToJSON ChatMessage where
  toJSON = \case
    MsgSystem c -> object ["role" .= ("system" :: Text), "content" .= c]
    MsgUser c -> object ["role" .= ("user" :: Text), "content" .= c]
    MsgUserBlocks blocks ->
      object
        [ "role" .= ("user" :: Text),
          "content" .= blocks
        ]
    MsgAssistant c -> object ["role" .= ("assistant" :: Text), "content" .= c]
    -- Emit the provider's message verbatim — field names and
    -- structure must survive the round-trip untouched.
    MsgAssistantToolCalls raw _ -> raw
    MsgTool cid c ->
      object
        [ "role" .= ("tool" :: Text),
          "tool_call_id" .= cid,
          "content" .= c
        ]

instance FromJSON ChatMessage where
  parseJSON = withObject "ChatMessage" $ \o -> do
    role <- o .: "role" :: Parser Text
    case role of
      "system" -> MsgSystem <$> o .: "content"
      "user" -> MsgUser <$> o .: "content"
      "tool" -> MsgTool <$> o .: "tool_call_id" <*> o .: "content"
      "assistant" -> do
        mTools <- o .:? "tool_calls"
        case mTools of
          Just tcs | not (null tcs) -> do
            tcs' <- traverse parseToolCall tcs
            pure (MsgAssistantToolCalls (Object o) tcs')
          _ -> do
            mC <- o .:? "content"
            pure (MsgAssistant (case mC of Just c -> c; Nothing -> ""))
      r -> fail $ "unknown chat role: " <> T.unpack r

parseToolCall :: Value -> Parser ToolCall
parseToolCall = withObject "ToolCall" $ \o -> do
  cid <- o .: "id"
  fn <- o .: "function" :: Parser Object
  -- Some Anthropic→OpenAI proxies (e.g. how88.top) leave 'name' at
  -- the tool-call top level instead of inside 'function'; try both.
  mNameInner <- fn .:? "name"
  mNameOuter <- o .:? "name"
  name <- case mNameInner <|> mNameOuter of
    Just n -> pure n
    Nothing -> fail "tool_call missing 'name' in both function.name and top-level"
  -- 'arguments' is sometimes absent for no-arg tools; default to {}.
  mArgsStr <- fn .:? "arguments" :: Parser (Maybe Text)
  args <- case mArgsStr of
    Nothing -> pure (Object mempty)
    Just s | T.null (T.strip s) -> pure (Object mempty)
    Just s -> case eitherDecode (LBS.fromStrict (TE.encodeUtf8 s)) of
      Right v -> pure v
      Left e -> fail $ "decoding tool arguments JSON: " <> e
  pure (ToolCall cid name args)

--------------------------------------------------------------------------------
-- Effect.

data LLM :: Effect where
  Chat :: Text -> [ChatMessage] -> [ToolSpec] -> LLM m (Either Text ChatResponse)
  -- | 'Chat', but the assistant text is handed over as it arrives.
  --
  -- The sink receives the text /so far/, not the delta: the accumulator
  -- already holds the whole thing, and a caller deciding \"is a
  -- paragraph finished\" has to look at the accumulation anyway.  It
  -- runs on the reading thread, so a slow sink backpressures the socket
  -- — which is what we want, since it is sending QQ messages.
  --
  -- Falls back to a plain 'Chat' when the profile has streaming off;
  -- the sink is then simply never called, so callers need no branch.
  ChatStreaming ::
    Text ->
    [ChatMessage] ->
    [ToolSpec] ->
    (Text -> m ()) ->
    LLM m (Either Text ChatResponse)
  ListProfiles :: LLM m [Text]
  DefaultProfile :: LLM m Text
  -- | Look up @profile.multimodal@ by profile name.  Returns 'False'
  -- if the profile doesn't exist (caller will already fail on the
  -- subsequent 'Chat' call with a clearer error).
  IsProfileMultimodal :: Text -> LLM m Bool
  -- | Look up @profile.history_as_turns@ by name.  'False' when the
  -- profile doesn't exist — same fallback as 'IsProfileMultimodal'.
  IsProfileHistoryTurns :: Text -> LLM m Bool

type instance DispatchOf LLM = Dynamic

-- | Per-profile timeout is enforced twice: the http-client
-- 'HTTP.managerResponseTimeout' is set to @timeoutSeconds@ inside
-- 'postAndParse' (otherwise the manager's built-in 30s default kills
-- any generation slower than that — non-streaming endpoints send
-- nothing until the completion is done), and a 'System.Timeout.timeout'
-- wraps the whole call as the wallclock belt-and-braces.
runLLM ::
  (W.Wreq :> es, Log :> es, IOE :> es) =>
  LLMRegistry ->
  Eff (LLM : es) a ->
  Eff es a
runLLM reg = interpret $ \localEnv -> \case
  Chat name msgs tools -> runOneChat reg name msgs tools Nothing
  ChatStreaming name msgs tools sink ->
    -- The sink sends messages, so it is 'Eff', not IO; unlifting it
    -- here is what lets the transport call back into the caller's
    -- effect stack.  Sequential unlift is right: the read loop is
    -- single-threaded and calls the sink one frame at a time.
    localSeqUnlift localEnv $ \unlift ->
      runOneChat reg name msgs tools (Just (unlift . sink))
  ListProfiles -> pure (Map.keys reg.profiles)
  DefaultProfile -> pure reg.defaultName
  IsProfileMultimodal name -> pure $ case Map.lookup name reg.profiles of
    Just cfg -> cfg.multimodal
    Nothing -> False
  IsProfileHistoryTurns name -> pure $ case Map.lookup name reg.profiles of
    Just cfg -> cfg.historyAsTurns
    Nothing -> False

-- | One chat call, shared by the streaming and non-streaming
-- operations.  A 'Just' sink means \"stream if the profile allows it\";
-- 'Nothing', or a profile with @stream = false@, takes the ordinary
-- request-response path.
runOneChat ::
  (W.Wreq :> es, Log :> es, IOE :> es) =>
  LLMRegistry ->
  Text ->
  [ChatMessage] ->
  [ToolSpec] ->
  Maybe (Text -> Eff es ()) ->
  Eff es (Either Text ChatResponse)
runOneChat reg name msgs tools mSink = case Map.lookup name reg.profiles of
  Nothing -> do
    logAttention "llm: unknown profile" $ object ["profile" .= name]
    pure $ Left ("unknown llm profile: " <> name)
  Just cfg -> do
    let streaming = cfg.stream && isJust mSink
    logInfo "llm: chat request" $
      object
        [ "msg_count" .= length msgs,
          "tool_count" .= length tools,
          "profile" .= name,
          "model" .= cfg.model,
          "stream" .= streaming
        ]
    r <- case mSink of
      Just sink | cfg.stream -> callChatStream cfg msgs tools sink
      _ -> callChat cfg msgs tools
    case r of
      Left err ->
        logAttention "llm: error" $
          object ["error" .= err, "profile" .= name]
      Right (ContentResp text, mUsage) ->
        logInfo "llm: got content" $
          object $
            ["len" .= T.length text, "profile" .= name] <> usageFields mUsage
      Right (ToolCallsResp _ narration tcs, mUsage) ->
        logInfo "llm: got tool_calls" $
          object $
            [ "count" .= length tcs,
              "narration_len" .= T.length narration,
              "names" .= map (.callName) tcs,
              "profile" .= name
            ]
              <> usageFields mUsage
    pure (fst <$> r)

chat ::
  LLM :> es =>
  Text -> -- profile name
  [ChatMessage] ->
  [ToolSpec] ->
  Eff es (Either Text ChatResponse)
chat name msgs tools =
  send (Chat name msgs tools)

-- | 'chat' with a sink for the assistant text as it streams in.  See
-- 'ChatStreaming'.
chatStreaming ::
  LLM :> es =>
  Text ->
  [ChatMessage] ->
  [ToolSpec] ->
  (Text -> Eff es ()) ->
  Eff es (Either Text ChatResponse)
chatStreaming name msgs tools sink =
  send (ChatStreaming name msgs tools sink)

listProfiles :: LLM :> es => Eff es [Text]
listProfiles = send ListProfiles

defaultProfile :: LLM :> es => Eff es Text
defaultProfile = send DefaultProfile

isProfileMultimodal :: LLM :> es => Text -> Eff es Bool
isProfileMultimodal name = send (IsProfileMultimodal name)

isProfileHistoryTurns :: LLM :> es => Text -> Eff es Bool
isProfileHistoryTurns name = send (IsProfileHistoryTurns name)

-- | Usage as extra log fields; absent wholesale when the provider
-- reported none.
usageFields :: Maybe TokenUsage -> [Pair]
usageFields Nothing = []
usageFields (Just u) =
  [ "prompt_tokens" .= u.usagePrompt,
    "completion_tokens" .= u.usageCompletion
  ]
    <> maybe [] (\c -> ["cached_prompt_tokens" .= c]) u.usageCachedPrompt

--------------------------------------------------------------------------------
-- Shared HTTP helper.

--------------------------------------------------------------------------------
-- HTTP — dispatch on protocol.

-- | Chat-completion dispatch.  Picks 'callChatOpenAI' or
-- 'callChatAnthropic' based on 'profile.protocol'.  Each branch
-- handles its own wire format end-to-end (URL, headers, request
-- body, response parsing); only the timeout wrapping is shared.
callChat ::
  (W.Wreq :> es, Log :> es, IOE :> es) =>
  LLMProfile ->
  [ChatMessage] ->
  [ToolSpec] ->
  Eff es (Either Text (ChatResponse, Maybe TokenUsage))
callChat cfg msgs tools = case cfg.protocol of
  ProtocolOpenAI -> callChatOpenAI cfg msgs tools
  ProtocolAnthropic -> callChatAnthropic cfg msgs tools

--------------------------------------------------------------------------------
-- Streaming.

-- | Appended to a reply whose stream died before the provider said it
-- was finished.  The fragment stays: it is already in the group, and
-- the reader needs to know the sentence stops there because the
-- connection broke, not because the bot meant it to.
interruptionMarker :: Text
interruptionMarker = "\n\n⚠ 断了，上面这条没写完"

-- | Streamed chat completion.  Same request as 'callChat' plus the
-- provider's stream switches; the response is assembled from SSE
-- frames by "Max.LLM.Stream" instead of parsed from one JSON body.
callChatStream ::
  (Log :> es, IOE :> es) =>
  LLMProfile ->
  [ChatMessage] ->
  [ToolSpec] ->
  (Text -> Eff es ()) ->
  Eff es (Either Text (ChatResponse, Maybe TokenUsage))
callChatStream cfg msgs tools sink = case cfg.protocol of
  ProtocolOpenAI ->
    run
      (T.unpack (cfg.baseUrl <> "/chat/completions"))
      [ ("Authorization", "Bearer " <> TE.encodeUtf8 cfg.apiKey),
        ("Content-Type", "application/json"),
        ("Accept", "text/event-stream")
      ]
      (LBS.toStrict (encode (object (openAIFields cfg msgs tools <> streamFieldsOpenAI))))
      stepOpenAI
      rebuildOpenAI
  ProtocolAnthropic ->
    run
      (T.unpack (cfg.baseUrl <> "/v1/messages"))
      [ ("x-api-key", TE.encodeUtf8 cfg.apiKey),
        ("anthropic-version", "2023-06-01"),
        ("Content-Type", "application/json"),
        ("Accept", "text/event-stream")
      ]
      (LBS.toStrict (encode (object (anthropicFields cfg msgs tools <> [("stream", toJSON True)]))))
      stepAnthropic
      rebuildAnthropic
  where
    run url hdrs body step rebuild = do
      outcome <-
        streamPost defaultRetryDelaysSecs cfg.timeoutSeconds hdrs url body step $ \acc ->
          -- Strip before the sink, never after: models that inline
          -- their reasoning (MiniMax, GLM) open with a
          -- @\<think\>…\</think\>@ block, and streaming it straight
          -- out would put the monologue in the group.
          -- 'stripLeadingThink' returns "" for an unclosed block, so
          -- nothing escapes until the block ends.  The only window it
          -- doesn't cover is a half-arrived opening tag (@\<thi@),
          -- which can't contain the blank line a paragraph needs.
          sink (stripLeadingThink acc.saText)
      case outcome of
        StreamFailed err -> pure (Left err)
        StreamComplete acc -> pure (Right (rebuild acc, accUsage acc))
        StreamTruncated acc why -> do
          -- Tool-call arguments arrive as JSON text fragments, so a
          -- stream cut mid-call leaves arguments that are syntactically
          -- broken or — worse — accidentally valid but missing fields.
          -- Neither is safe to execute, so a truncated round degrades
          -- to whatever text it managed, plus the marker.
          logAttention "llm: stream truncated" $
            object
              [ "reason" .= why,
                "len" .= T.length acc.saText,
                "partial_calls" .= length (accToolCalls acc)
              ]
          pure (Right (ContentResp (stripLeadingThink acc.saText <> interruptionMarker), accUsage acc))

    accUsage acc = case (acc.saPromptTokens, acc.saCompletionTokens) of
      (Just p, Just c) -> Just (TokenUsage p c acc.saCachedTokens)
      -- Several gateways send no usage frame at all when streaming.
      -- Half a reading would be worse than none: it would look like a
      -- 0% cache hit rather than an absent measurement.
      _ -> Nothing

-- | @stream_options@ is required or an OpenAI-compatible endpoint
-- reports no usage whatsoever for a streamed call — and
-- @cached_tokens@ is the only way to see whether prefix caching is
-- working.
streamFieldsOpenAI :: [Pair]
streamFieldsOpenAI =
  [ "stream" .= True,
    "stream_options" .= object ["include_usage" .= True]
  ]

-- | Rebuild an OpenAI assistant message from the accumulator.
--
-- 'ToolCallsResp' normally carries the provider's message byte-for-byte
-- so its reasoning fields round-trip (DeepSeek 400s when
-- @reasoning_content@ goes missing).  A stream never sends that message
-- — it sends deltas — so "Max.LLM.Stream" merges them back into one,
-- and this reads the result rather than re-deriving a message from the
-- few fields we happen to model.
--
-- @tool_calls@ is the exception: it comes from 'parsedCalls', not from
-- the merged message.  A call whose arguments never finished arriving
-- is dropped, and replaying a call we never executed would leave the
-- provider waiting for a tool result that can't exist.  What we send
-- back must match what we answer.
rebuildOpenAI :: StreamAcc -> ChatResponse
rebuildOpenAI acc = case parsedCalls acc of
  [] -> ContentResp (stripLeadingThink acc.saText)
  tcs ->
    ToolCallsResp
      (withFields acc.saMessage (roleField <> [("tool_calls", toJSON (map wireCall tcs))]))
      (stripLeadingThink acc.saText)
      tcs
  where
    -- Present in the first delta; supplied only if some gateway omits it.
    roleField
      | hasKey "role" acc.saMessage = []
      | otherwise = ["role" .= ("assistant" :: Text)]
    wireCall tc =
      object
        [ "id" .= tc.callId,
          "type" .= ("function" :: Text),
          "function"
            .= object
              [ "name" .= tc.callName,
                -- Back to the stringified form the wire wants; we parsed
                -- it only to check it was whole.
                "arguments" .= TE.decodeUtf8 (LBS.toStrict (encode tc.callArguments))
              ]
        ]

-- | Rebuild an Anthropic assistant turn from the accumulated content
-- blocks, in wire order and in the shape the provider opened them with.
--
-- @thinking@ blocks replay intact: the API streams a @signature_delta@
-- just before the block closes precisely so a client can rebuild one,
-- and a thinking block without its signature is rejected.  Blocks of a
-- type we don't model survive too, because they are carried rather than
-- paraphrased.
--
-- @tool_use@ blocks take their @input@ from 'parsedCalls' — the deltas
-- carry it as partial JSON text, and a call that never finished
-- arriving is dropped from both the replay and the execution list, for
-- the reason 'rebuildOpenAI' gives.
rebuildAnthropic :: StreamAcc -> ChatResponse
rebuildAnthropic acc = case parsedCalls acc of
  [] -> ContentResp (stripLeadingThink acc.saText)
  tcs ->
    ToolCallsResp
      (object ["role" .= ("assistant" :: Text), "content" .= content tcs])
      (stripLeadingThink acc.saText)
      tcs
  where
    content tcs =
      [ block
        | b <- Map.elems acc.saBlocks,
          Just block <- [finish tcs b]
      ]
    finish tcs b = case fieldOf "type" b of
      Just (String "tool_use") -> do
        cid <- fieldOf "id" b
        tc <- find ((== cid) . toJSON . (.callId)) tcs
        pure (withFields b ["input" .= tc.callArguments])
      _ -> Just b

fieldOf :: Key -> Value -> Maybe Value
fieldOf k (Object o) = KM.lookup k o
fieldOf _ _ = Nothing

hasKey :: Key -> Value -> Bool
hasKey k (Object o) = KM.member k o
hasKey _ _ = False

-- | Overwrite fields on a JSON object, leaving everything else as it
-- came off the wire.
withFields :: Value -> [Pair] -> Value
withFields (Object o) extra = Object (KM.union (KM.fromList extra) o')
  where
    o' = foldr (KM.delete . fst) o extra
withFields v _ = v

-- | Tool calls whose accumulated argument text is whole, valid JSON.
-- A call that isn't gets dropped rather than executed on a guess: the
-- fragments are individually invalid by design, so \"didn't parse\"
-- means \"didn't finish arriving\".
parsedCalls :: StreamAcc -> [ToolCall]
parsedCalls acc =
  [ ToolCall pc.pcId pc.pcName v
    | pc <- accToolCalls acc,
      Just v <- [argsOf pc.pcArgs]
  ]
  where
    argsOf t
      | T.null (T.strip t) = Just (Object mempty)
      | otherwise = decodeStrict' (TE.encodeUtf8 t)

--------------------------------------------------------------------------------
-- OpenAI / OpenAI-compatible: POST {baseUrl}/chat/completions.

callChatOpenAI ::
  (W.Wreq :> es, Log :> es, IOE :> es) =>
  LLMProfile ->
  [ChatMessage] ->
  [ToolSpec] ->
  Eff es (Either Text (ChatResponse, Maybe TokenUsage))
callChatOpenAI cfg msgs tools = do
  let body =
        LBS.toStrict
          (encode (object (openAIFields cfg msgs tools <> ["stream" .= False])))
      url = T.unpack (cfg.baseUrl <> "/chat/completions")
      opts =
        Wreq.defaults
          & WL.header "Authorization" .~ ["Bearer " <> TE.encodeUtf8 cfg.apiKey]
          & WL.header "Content-Type" .~ ["application/json"]
  postAndParseRetrying defaultRetryDelaysSecs cfg.timeoutSeconds opts url body parseResponseOpenAI

-- | Everything an OpenAI chat-completions request carries except the
-- stream switches, so the streaming and non-streaming paths can't drift
-- apart on what they actually ask for.
openAIFields :: LLMProfile -> [ChatMessage] -> [ToolSpec] -> [Pair]
openAIFields cfg msgs tools =
  [ "model" .= cfg.model,
    "messages" .= msgs,
    "max_tokens" .= cfg.maxTokens
  ]
    <> temperatureField cfg
    <> [ f
         | not (null tools),
           f <-
             [ "tools" .= map encodeToolSpecOpenAI tools,
               "tool_choice" .= ("auto" :: Text)
             ]
       ]

-- | @temperature@ only when configured — omitting lets the server
-- pick its default, and some providers 400 on explicit values.
temperatureField :: LLMProfile -> [Pair]
temperatureField cfg = case cfg.temperature of
  Just t -> ["temperature" .= t]
  Nothing -> []

encodeToolSpecOpenAI :: ToolSpec -> Value
encodeToolSpecOpenAI t =
  object
    [ "type" .= ("function" :: Text),
      "function"
        .= object
          [ "name" .= t.specName,
            "description" .= t.specDescription,
            "parameters" .= t.specSchema
          ]
    ]

-- | Pull @choices[0].message@ off an OpenAI-style chat response.
-- For responses with tool_calls, the raw message object rides along
-- verbatim in the 'ToolCallsResp' so the agent loop can replay it
-- unchanged in the next request — thinking output must go back in
-- whatever field/structure the provider used (DeepSeek 400s when
-- its @reasoning_content@ goes missing).
-- Usage extraction is lenient: a missing or mangled @usage@ block
-- must never fail an otherwise-good response.
parseResponseOpenAI :: Value -> Parser (ChatResponse, Maybe TokenUsage)
parseResponseOpenAI = withObject "ChatResponse" $ \o -> do
  choices <- o .: "choices"
  resp <- case choices of
    (c : _) -> withObject "Choice" parseChoice c
    [] -> fail "no choices in response"
  mUsageV <- o .:? "usage"
  pure (resp, parseMaybe parseUsageOpenAI =<< mUsageV)
  where
    parseChoice c = do
      m <- c .: "message" :: Parser Object
      mTools <- m .:? "tool_calls"
      case mTools of
        Just tcs | not (null tcs) -> do
          tcs' <- traverse parseToolCall tcs
          -- content and tool_calls can both be populated — the schema
          -- allows it and models do it.  Keep the narration; the agent
          -- loop posts it as the progress line the user would otherwise
          -- be waiting through in silence.
          mNarr <- m .:? "content"
          pure (ToolCallsResp (Object m) (maybe "" stripLeadingThink mNarr) tcs')
        _ -> do
          mC <- m .:? "content"
          case mC of
            Just c' -> pure (ContentResp (stripLeadingThink c'))
            Nothing -> fail "no content nor tool_calls in message"

-- | Models that inline their reasoning (MiniMax, GLM, …) open the
-- content with a @\<think\>…\</think\>@ block instead of using a
-- separate reasoning field.  Strip a leading block before handing the
-- text to callers — it must never reach the group.  Content that got
-- truncated inside the block (hit max_tokens mid-think) strips to
-- empty rather than leaking half a monologue.  Tool-call turns are
-- unaffected: their raw message round-trips verbatim, block included.
stripLeadingThink :: Text -> Text
stripLeadingThink t =
  case T.stripPrefix "<think>" (T.stripStart t) of
    Nothing -> t
    Just rest -> case T.breakOn "</think>" rest of
      (_, suf)
        | Just after <- T.stripPrefix "</think>" suf -> T.stripStart after
        | otherwise -> ""

-- | OpenAI-shaped usage block.  The cached-prompt count hides in two
-- places depending on provider: DeepSeek's flat
-- @prompt_cache_hit_tokens@, OpenAI's nested
-- @prompt_tokens_details.cached_tokens@.
parseUsageOpenAI :: Value -> Parser TokenUsage
parseUsageOpenAI = withObject "usage" $ \u -> do
  p <- u .: "prompt_tokens"
  c <- u .: "completion_tokens"
  mHit <- u .:? "prompt_cache_hit_tokens"
  mDetails <- u .:? "prompt_tokens_details"
  mCached <- case mDetails of
    Just (Object d) -> d .:? "cached_tokens"
    _ -> pure Nothing
  pure (TokenUsage p c (mHit <|> mCached))

--------------------------------------------------------------------------------
-- Anthropic Messages API: POST {baseUrl}/v1/messages.

callChatAnthropic ::
  (W.Wreq :> es, Log :> es, IOE :> es) =>
  LLMProfile ->
  [ChatMessage] ->
  [ToolSpec] ->
  Eff es (Either Text (ChatResponse, Maybe TokenUsage))
callChatAnthropic cfg msgs tools = do
  let body = LBS.toStrict (encode (object (anthropicFields cfg msgs tools)))
      url = T.unpack (cfg.baseUrl <> "/v1/messages")
      opts =
        Wreq.defaults
          & WL.header "x-api-key" .~ [TE.encodeUtf8 cfg.apiKey]
          & WL.header "anthropic-version" .~ ["2023-06-01"]
          & WL.header "Content-Type" .~ ["application/json"]
  postAndParseRetrying defaultRetryDelaysSecs cfg.timeoutSeconds opts url body parseResponseAnthropic

-- | The Anthropic counterpart of 'openAIFields', minus @stream@.
--
-- Anthropic caches nothing without explicit breakpoints.  Two are
-- enough (the limit is 4): one on the system block covers the tools +
-- system prefix across dispatches; one on the last message makes each
-- agent-loop turn a full prefix hit of the previous one.
anthropicFields :: LLMProfile -> [ChatMessage] -> [ToolSpec] -> [Pair]
anthropicFields cfg msgs tools =
  [ "model" .= cfg.model,
    "max_tokens" .= cfg.maxTokens,
    "messages" .= map encodeAnthropicMsg (markLastForCache anthropicMsgs)
  ]
    <> temperatureField cfg
    <> systemField
    <> [ f
         | not (null tools),
           f <-
             [ "tools" .= map encodeToolSpecAnthropic tools,
               "tool_choice" .= object ["type" .= ("auto" :: Text)]
             ]
       ]
  where
    (systemText, anthropicMsgs) = toAnthropicMessages msgs
    systemField = case systemText of
      Just s ->
        [ "system"
            .= [ object
                   [ "type" .= ("text" :: Text),
                     "text" .= s,
                     "cache_control" .= ephemeralCache
                   ]
               ]
        ]
      Nothing -> []

encodeToolSpecAnthropic :: ToolSpec -> Value
encodeToolSpecAnthropic t =
  object
    [ "name" .= t.specName,
      "description" .= t.specDescription,
      -- Anthropic's @input_schema@ replaces OpenAI's @parameters@.
      "input_schema" .= t.specSchema
    ]

-- | One Anthropic message: @role@ + @content@ where content is either
-- a plain string (simple turn) or an array of content blocks (tool
-- turns).  We just carry the raw 'Value' to skip an intermediate type.
data AnthropicMsg = AnthropicMsg !Text !Value

ephemeralCache :: Value
ephemeralCache = object ["type" .= ("ephemeral" :: Text)]

-- | Put a @cache_control@ breakpoint on the request's final content
-- block, so the next request in the agent loop (same messages + a few
-- appended) reads everything up to here from cache.  A plain-string
-- content is promoted to a one-block array; an empty array is left
-- alone.
markLastForCache :: [AnthropicMsg] -> [AnthropicMsg]
markLastForCache [] = []
markLastForCache ms = init ms <> [mark (last ms)]
  where
    mark (AnthropicMsg role content) = AnthropicMsg role (go content)
    go = \case
      String s ->
        toJSON
          [ object
              [ "type" .= ("text" :: Text),
                "text" .= s,
                "cache_control" .= ephemeralCache
              ]
          ]
      Array blocks
        | not (V.null blocks) ->
            Array (V.init blocks <> V.singleton (addCC (V.last blocks)))
      other -> other
    addCC (Object o) = Object (KM.insert "cache_control" ephemeralCache o)
    addCC v = v

encodeAnthropicMsg :: AnthropicMsg -> Value
encodeAnthropicMsg (AnthropicMsg role content) =
  object ["role" .= role, "content" .= content]

-- | Split a @data:\<mime\>;base64,\<payload\>@ URL back into
-- (mime, payload) for Anthropic's image-block shape.
splitDataUrl :: Text -> Maybe (Text, Text)
splitDataUrl url = do
  rest <- T.stripPrefix "data:" url
  let (mime, after) = T.breakOn ";base64," rest
  b64 <- T.stripPrefix ";base64," after
  if T.null mime then Nothing else Just (mime, b64)

-- | Convert our 'ChatMessage' sequence to (system-prompt, message-list)
-- in Anthropic shape:
--
--   * All 'MsgSystem' texts are joined and pulled into the top-level
--     @system@ field (Anthropic doesn't accept @role: system@ inside
--     the messages array).
--   * Consecutive 'MsgTool' messages are coalesced into a single
--     @role: user@ message with multiple @tool_result@ blocks — that
--     matches how Claude expects to see tool results after a single
--     assistant turn with multiple @tool_use@ blocks.
--   * 'MsgAssistantToolCalls' becomes an assistant message whose
--     content is an array of @tool_use@ blocks.
toAnthropicMessages :: [ChatMessage] -> (Maybe Text, [AnthropicMsg])
toAnthropicMessages msgs = (systemPrompt, go nonSystems)
  where
    systems = [t | MsgSystem t <- msgs]
    nonSystems = [m | m <- msgs, not (isSystem m)]
    systemPrompt = case systems of
      [] -> Nothing
      _ -> Just (T.intercalate "\n\n" systems)

    isSystem (MsgSystem _) = True
    isSystem _ = False

    go [] = []
    go (MsgUser t : rest) = AnthropicMsg "user" (toJSON t) : go rest
    go (MsgUserBlocks blocks : rest) =
      -- Anthropic image blocks carry @source: {type:base64,
      -- media_type, data}@ rather than OpenAI's data-URL
      -- @image_url@, so split our data URLs back apart.  A URL that
      -- doesn't parse degrades to a text marker.
      let content =
            [ case b of
                TextBlock t -> object ["type" .= ("text" :: Text), "text" .= t]
                -- Anthropic has no video input type.
                VideoDataUrl _ ->
                  object ["type" .= ("text" :: Text), "text" .= ("[video：该模型协议不支持视频输入]" :: Text)]
                ImageDataUrl url -> case splitDataUrl url of
                  Just (mime, b64) ->
                    object
                      [ "type" .= ("image" :: Text),
                        "source"
                          .= object
                            [ "type" .= ("base64" :: Text),
                              "media_type" .= mime,
                              "data" .= b64
                            ]
                      ]
                  Nothing ->
                    object ["type" .= ("text" :: Text), "text" .= ("[image]" :: Text)]
              | b <- blocks
            ]
       in AnthropicMsg "user" (toJSON content) : go rest
    go (MsgAssistant t : rest) = AnthropicMsg "assistant" (toJSON t) : go rest
    go (MsgAssistantToolCalls raw tcs : rest) =
      -- Replay the assistant turn's content blocks verbatim —
      -- thinking/text blocks must survive the round-trip.  Rebuild
      -- bare tool_use blocks only when the raw message isn't
      -- Anthropic-shaped (content not an array — e.g. history from
      -- an OpenAI-protocol profile).
      let rebuilt =
            [ object
                [ "type" .= ("tool_use" :: Text),
                  "id" .= tc.callId,
                  "name" .= tc.callName,
                  "input" .= tc.callArguments
                ]
              | tc <- tcs
            ]
          content = case raw of
            Object o | Just blocks@(Array _) <- KM.lookup "content" o -> blocks
            _ -> toJSON rebuilt
       in AnthropicMsg "assistant" content : go rest
    go ms@(MsgTool _ _ : _) =
      let (toolMsgs, after) = span isToolMsg ms
          blocks =
            [ object
                [ "type" .= ("tool_result" :: Text),
                  "tool_use_id" .= tcid,
                  "content" .= c
                ]
              | MsgTool tcid c <- toolMsgs
            ]
       in AnthropicMsg "user" (toJSON blocks) : go after
    go (MsgSystem _ : rest) = go rest -- already pulled out

    isToolMsg (MsgTool _ _) = True
    isToolMsg _ = False

-- | Parse Anthropic Messages API response: walk the @content@ array,
-- collect @text@ blocks and @tool_use@ blocks.  If any tool_use
-- present → 'ToolCallsResp' carrying the whole content array verbatim
-- (thinking/text blocks included) so the next request replays the
-- assistant turn exactly as Claude produced it.  Else if any text →
-- 'ContentResp' with the concatenation.  Usage extraction is lenient,
-- same as the OpenAI path.
parseResponseAnthropic :: Value -> Parser (ChatResponse, Maybe TokenUsage)
parseResponseAnthropic = withObject "AnthropicResponse" $ \o -> do
  blocks <- o .: "content" :: Parser [Value]
  parsed <- traverse parseBlock blocks
  let toolCalls = [tc | Just (Right tc) <- parsed]
      texts = [t | Just (Left t) <- parsed]
      rawMsg = object ["role" .= ("assistant" :: Text), "content" .= blocks]
  resp <-
    if not (null toolCalls)
      then pure (ToolCallsResp rawMsg (T.concat texts) toolCalls)
      else
        if not (null texts)
          then pure (ContentResp (T.concat texts))
          else fail "no text nor tool_use blocks in response.content"
  mUsageV <- o .:? "usage"
  pure (resp, parseMaybe parseUsageAnthropic =<< mUsageV)
  where
    parseBlock :: Value -> Parser (Maybe (Either Text ToolCall))
    parseBlock = withObject "ContentBlock" $ \b -> do
      ty <- b .: "type" :: Parser Text
      case ty of
        "text" -> Just . Left <$> b .: "text"
        "tool_use" -> do
          tcid <- b .: "id"
          name <- b .: "name"
          -- Anthropic's @input@ is already a JSON object — no
          -- stringified-JSON ceremony like OpenAI requires.
          inp <- b .: "input"
          pure (Just (Right (ToolCall tcid name inp)))
        -- thinking / redacted_thinking / future block types: not ours
        -- to interpret; they still replay verbatim via the raw message.
        _ -> pure Nothing

-- | Anthropic usage block.  @input_tokens@ counts only uncached
-- prompt tokens; cache reads ride separately in
-- @cache_read_input_tokens@.
parseUsageAnthropic :: Value -> Parser TokenUsage
parseUsageAnthropic = withObject "usage" $ \u ->
  TokenUsage
    <$> u .: "input_tokens"
    <*> u .: "output_tokens"
    <*> u .:? "cache_read_input_tokens"
