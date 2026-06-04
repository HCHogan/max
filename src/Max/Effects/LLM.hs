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
    ToolCall (..),
    -- * Tool descriptions for the wire
    ToolSpec (..),
    -- * Response
    ChatResponse (..),
    -- * Effect operations
    runLLM,
    chat,
    listProfiles,
    defaultProfile,
  )
where

import Control.Applicative ((<|>))
import Control.Exception (SomeException, try)
import Control.Lens ((&), (.~), (?~), (^.))
import Data.Aeson
import Data.Aeson.Types (Parser, parseEither)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Effectful
import Effectful.Dispatch.Dynamic (interpret, send)
import Effectful.Log
import Effectful.Wreq qualified as W
import Network.HTTP.Types.Status (statusCode)
import Network.Wreq qualified as Wreq
import Network.Wreq.Lens qualified as WL
import System.Timeout (timeout)

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
    temperature :: !Double,
    -- | HTTP timeout for one chat completion.  LLMs are slow, default 120.
    timeoutSeconds :: !Int,
    -- | Wire format spoken by the endpoint.  Default 'ProtocolOpenAI'.
    protocol :: !Protocol,
    -- | Whether to enable thinking mode.  'Nothing' = don't send the
    -- field, server uses its default (DeepSeek default = enabled).
    -- 'Just True' / 'Just False' = explicitly send
    -- @{"thinking": {"type": "enabled"|"disabled"}}@ in the OpenAI
    -- request body.  Ignored for Anthropic protocol (Claude has its
    -- own thinking-block format).
    thinking :: !(Maybe Bool)
  }
  deriving stock (Show)

-- | The full profile registry.  'runLLM' takes one of these; downstream
-- code picks profiles by name.
data LLMRegistry = LLMRegistry
  { defaultName :: !Text,
    profiles :: !(Map Text LLMProfile)
  }
  deriving stock (Show)

-- | A single message in the chat history.  Mirrors OpenAI's role
-- enum.  Sum-typed so we can keep tool turns first-class instead of
-- carrying optional fields around.
data ChatMessage
  = -- | @{ role: "system", content: ... }@
    MsgSystem !Text
  | -- | @{ role: "user", content: ... }@
    MsgUser !Text
  | -- | Plain assistant text response.  Any 'reasoning_content' from
    -- the original response is dropped — per DeepSeek docs it's not
    -- needed in subsequent turns when no tool call happened.
    MsgAssistant !Text
  | -- | Assistant chose to call one or more tools.  Carries the
    -- optional @reasoning_content@ from the thinking model — must
    -- round-trip to the API in the *next* request within the same
    -- agent dispatch, or the API returns 400.  'Nothing' for
    -- non-thinking models.
    MsgAssistantToolCalls !(Maybe Text) ![ToolCall]
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
    -- optional first field is the model's @reasoning_content@
    -- (DeepSeek thinking mode); when 'Just', it MUST be carried
    -- into the next assistant message's @reasoning_content@ field
    -- or DeepSeek returns 400.
    ToolCallsResp !(Maybe Text) ![ToolCall]
  deriving stock (Show)

--------------------------------------------------------------------------------
-- JSON.

instance ToJSON ChatMessage where
  toJSON = \case
    MsgSystem c -> object ["role" .= ("system" :: Text), "content" .= c]
    MsgUser c -> object ["role" .= ("user" :: Text), "content" .= c]
    MsgAssistant c -> object ["role" .= ("assistant" :: Text), "content" .= c]
    MsgAssistantToolCalls mReasoning tcs ->
      object $
        [ "role" .= ("assistant" :: Text),
          "content" .= Null,
          "tool_calls" .= map encodeToolCall tcs
        ]
          <> case mReasoning of
            Just r -> ["reasoning_content" .= r]
            Nothing -> []
    MsgTool cid c ->
      object
        [ "role" .= ("tool" :: Text),
          "tool_call_id" .= cid,
          "content" .= c
        ]

encodeToolCall :: ToolCall -> Value
encodeToolCall tc =
  object
    [ "id" .= tc.callId,
      "type" .= ("function" :: Text),
      "function"
        .= object
          [ "name" .= tc.callName,
            -- OpenAI insists arguments be a JSON-encoded string.
            "arguments" .= TE.decodeUtf8 (LBS.toStrict (encode tc.callArguments))
          ]
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
        mReasoning <- o .:? "reasoning_content"
        case mTools of
          Just tcs | not (null tcs) -> do
            tcs' <- traverse parseToolCall tcs
            pure (MsgAssistantToolCalls mReasoning tcs')
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
  -- | The optional 'Maybe Bool' is a per-call thinking-mode
  -- override.  When 'Nothing', use the profile's setting (which may
  -- itself be 'Nothing', meaning don't send the field at all).
  -- When 'Just', overrides whatever the profile says.
  Chat :: Text -> Maybe Bool -> [ChatMessage] -> [ToolSpec] -> LLM m (Either Text ChatResponse)
  ListProfiles :: LLM m [Text]
  DefaultProfile :: LLM m Text

type instance DispatchOf LLM = Dynamic

-- | All chat completions go through wreq's default 'Manager' (a
-- shared singleton).  Per-profile timeout is enforced via
-- 'System.Timeout.timeout' around each call — wreq's 'Options' does
-- not expose response timeout, only the 'Manager' does, and we don't
-- want to maintain one 'Manager' per profile just for that.
runLLM ::
  (W.Wreq :> es, Log :> es, IOE :> es) =>
  LLMRegistry ->
  Eff (LLM : es) a ->
  Eff es a
runLLM reg = interpret $ \_ -> \case
  Chat name thinkingOverride msgs tools -> case Map.lookup name reg.profiles of
    Nothing -> do
      logAttention "llm: unknown profile" $ object ["profile" .= name]
      pure $ Left ("unknown llm profile: " <> name)
    Just cfg -> do
      let effThinking = thinkingOverride <|> cfg.thinking
      logInfo "llm: chat request" $
        object
          [ "msg_count" .= length msgs,
            "tool_count" .= length tools,
            "profile" .= name,
            "model" .= cfg.model,
            "thinking" .= effThinking
          ]
      r <- callChat cfg effThinking msgs tools
      case r of
        Left err ->
          logAttention "llm: error" $
            object ["error" .= err, "profile" .= name]
        Right (ContentResp text) ->
          logInfo "llm: got content" $
            object ["len" .= T.length text, "profile" .= name]
        Right (ToolCallsResp _ tcs) ->
          logInfo "llm: got tool_calls" $
            object
              [ "count" .= length tcs,
                "names" .= map (.callName) tcs,
                "profile" .= name
              ]
      pure r
  ListProfiles -> pure (Map.keys reg.profiles)
  DefaultProfile -> pure reg.defaultName

chat ::
  LLM :> es =>
  Text -> -- profile name
  Maybe Bool -> -- per-call thinking override; Nothing = use profile's
  [ChatMessage] ->
  [ToolSpec] ->
  Eff es (Either Text ChatResponse)
chat name thinkingOverride msgs tools =
  send (Chat name thinkingOverride msgs tools)

listProfiles :: LLM :> es => Eff es [Text]
listProfiles = send ListProfiles

defaultProfile :: LLM :> es => Eff es Text
defaultProfile = send DefaultProfile

--------------------------------------------------------------------------------
-- Shared HTTP helper.

-- | POST a request and run the protocol-specific parser on the
-- response body.  Wraps the wreq call in 'System.Timeout' to enforce
-- the per-profile wallclock cap (wreq's 'Options' has no
-- @responseTimeout@ slot).  Surfaces structured 'Left' errors for
-- timeout / transport / HTTP-status / JSON-parse / extract failures
-- with the response body preview attached so log readers see what
-- the upstream actually sent.
postAndParse ::
  (W.Wreq :> es, IOE :> es) =>
  LLMProfile ->
  Wreq.Options ->
  String -> -- url
  BS.ByteString -> -- body
  (Value -> Parser ChatResponse) -> -- parser
  Eff es (Either Text ChatResponse)
postAndParse cfg opts url body parser = do
  res <- withRunInIO $ \run ->
    timeout (cfg.timeoutSeconds * 1_000_000) $
      try (run (W.postWith opts url body))
  pure $ case res of
    Nothing -> Left "request timed out"
    Just (Left e) -> Left ("http: " <> T.pack (show (e :: SomeException)))
    Just (Right resp) ->
      let code = statusCode (resp ^. WL.responseStatus)
          rbody = resp ^. WL.responseBody
       in if code >= 400
            then
              Left $
                "HTTP "
                  <> T.pack (show code)
                  <> ": "
                  <> T.take 500 (TE.decodeUtf8Lenient (LBS.toStrict rbody))
            else
              let bodyPreview =
                    T.take 800 (TE.decodeUtf8Lenient (LBS.toStrict rbody))
               in case eitherDecode rbody of
                    Left e ->
                      Left ("parse: " <> T.pack e <> "\nbody: " <> bodyPreview)
                    Right v -> case parseEither parser v of
                      Left e ->
                        Left ("extract: " <> T.pack e <> "\nbody: " <> bodyPreview)
                      Right r -> Right r

--------------------------------------------------------------------------------
-- HTTP — dispatch on protocol.

-- | Chat-completion dispatch.  Picks 'callChatOpenAI' or
-- 'callChatAnthropic' based on 'profile.protocol'.  Each branch
-- handles its own wire format end-to-end (URL, headers, request
-- body, response parsing); only the timeout wrapping is shared.
callChat ::
  (W.Wreq :> es, IOE :> es) =>
  LLMProfile ->
  Maybe Bool -> -- effective thinking
  [ChatMessage] ->
  [ToolSpec] ->
  Eff es (Either Text ChatResponse)
callChat cfg thinkingEff msgs tools = case cfg.protocol of
  ProtocolOpenAI -> callChatOpenAI cfg thinkingEff msgs tools
  -- Anthropic protocol has its own thinking spec we don't bridge yet;
  -- ignore the override on this path.
  ProtocolAnthropic -> callChatAnthropic cfg msgs tools

--------------------------------------------------------------------------------
-- OpenAI / OpenAI-compatible: POST {baseUrl}/chat/completions.

callChatOpenAI ::
  (W.Wreq :> es, IOE :> es) =>
  LLMProfile ->
  Maybe Bool -> -- effective thinking
  [ChatMessage] ->
  [ToolSpec] ->
  Eff es (Either Text ChatResponse)
callChatOpenAI cfg thinkingEff msgs tools = do
  let baseFields =
        [ "model" .= cfg.model,
          "messages" .= msgs,
          "max_tokens" .= cfg.maxTokens,
          "temperature" .= cfg.temperature,
          "stream" .= False
        ]
      toolFields =
        if null tools
          then []
          else
            [ "tools" .= map encodeToolSpecOpenAI tools,
              "tool_choice" .= ("auto" :: Text)
            ]
      -- DeepSeek thinking-mode wire: top-level `thinking: {type: ...}`
      -- and optionally reasoning_effort=high.  Skip when 'Nothing'
      -- (= follow server default; non-DeepSeek endpoints get no
      -- unknown fields).
      thinkingFields = case thinkingEff of
        Nothing -> []
        Just True ->
          [ "thinking" .= object ["type" .= ("enabled" :: Text)],
            "reasoning_effort" .= ("high" :: Text)
          ]
        Just False ->
          ["thinking" .= object ["type" .= ("disabled" :: Text)]]
      body =
        LBS.toStrict
          (encode (object (baseFields <> toolFields <> thinkingFields)))
      url = T.unpack (cfg.baseUrl <> "/chat/completions")
      opts =
        Wreq.defaults
          & WL.header "Authorization" .~ ["Bearer " <> TE.encodeUtf8 cfg.apiKey]
          & WL.header "Content-Type" .~ ["application/json"]
          & WL.checkResponse ?~ (\_ _ -> pure ())
  postAndParse cfg opts url body parseResponseOpenAI

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
-- For thinking-model responses with tool_calls, extracts the
-- accompanying @reasoning_content@ and stuffs it into the
-- 'ToolCallsResp' so the agent loop can carry it forward into the
-- next request (DeepSeek requires this — missing → 400).
parseResponseOpenAI :: Value -> Parser ChatResponse
parseResponseOpenAI = withObject "ChatResponse" $ \o -> do
  choices <- o .: "choices"
  case choices of
    (c : _) -> withObject "Choice" parseChoice c
    [] -> fail "no choices in response"
  where
    parseChoice c = do
      m <- c .: "message" :: Parser Object
      mTools <- m .:? "tool_calls"
      case mTools of
        Just tcs | not (null tcs) -> do
          tcs' <- traverse parseToolCall tcs
          reasoning <- m .:? "reasoning_content"
          pure (ToolCallsResp reasoning tcs')
        _ -> do
          mC <- m .:? "content"
          case mC of
            Just c' -> pure (ContentResp c')
            Nothing -> fail "no content nor tool_calls in message"

--------------------------------------------------------------------------------
-- Anthropic Messages API: POST {baseUrl}/v1/messages.

callChatAnthropic ::
  (W.Wreq :> es, IOE :> es) =>
  LLMProfile ->
  [ChatMessage] ->
  [ToolSpec] ->
  Eff es (Either Text ChatResponse)
callChatAnthropic cfg msgs tools = do
  let (systemText, anthropicMsgs) = toAnthropicMessages msgs
      baseFields =
        [ "model" .= cfg.model,
          "max_tokens" .= cfg.maxTokens,
          "temperature" .= cfg.temperature,
          "messages" .= map encodeAnthropicMsg anthropicMsgs
        ]
      systemField = case systemText of
        Just s -> ["system" .= s]
        Nothing -> []
      toolFields =
        if null tools
          then []
          else
            [ "tools" .= map encodeToolSpecAnthropic tools,
              "tool_choice" .= object ["type" .= ("auto" :: Text)]
            ]
      body = LBS.toStrict (encode (object (baseFields <> systemField <> toolFields)))
      url = T.unpack (cfg.baseUrl <> "/v1/messages")
      opts =
        Wreq.defaults
          & WL.header "x-api-key" .~ [TE.encodeUtf8 cfg.apiKey]
          & WL.header "anthropic-version" .~ ["2023-06-01"]
          & WL.header "Content-Type" .~ ["application/json"]
          & WL.checkResponse ?~ (\_ _ -> pure ())
  postAndParse cfg opts url body parseResponseAnthropic

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

encodeAnthropicMsg :: AnthropicMsg -> Value
encodeAnthropicMsg (AnthropicMsg role content) =
  object ["role" .= role, "content" .= content]

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
    go (MsgAssistant t : rest) = AnthropicMsg "assistant" (toJSON t) : go rest
    go (MsgAssistantToolCalls _reasoning tcs : rest) =
      -- Anthropic has its own native thinking-block format; we don't
      -- bridge OpenAI 'reasoning_content' over (drop on this path).
      let blocks =
            [ object
                [ "type" .= ("tool_use" :: Text),
                  "id" .= tc.callId,
                  "name" .= tc.callName,
                  "input" .= tc.callArguments
                ]
              | tc <- tcs
            ]
       in AnthropicMsg "assistant" (toJSON blocks) : go rest
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
-- present → 'ToolCallsResp' (drops the text blocks, which are
-- typically Claude's pre-call thinking).  Else if any text →
-- 'ContentResp' with the concatenation.
parseResponseAnthropic :: Value -> Parser ChatResponse
parseResponseAnthropic = withObject "AnthropicResponse" $ \o -> do
  blocks <- o .: "content" :: Parser [Value]
  parsed <- traverse parseBlock blocks
  let toolCalls = [tc | Right tc <- parsed]
      texts = [t | Left t <- parsed]
  if not (null toolCalls)
    then pure (ToolCallsResp Nothing toolCalls)
    else
      if not (null texts)
        then pure (ContentResp (T.concat texts))
        else fail "no text nor tool_use blocks in response.content"
  where
    parseBlock :: Value -> Parser (Either Text ToolCall)
    parseBlock = withObject "ContentBlock" $ \b -> do
      ty <- b .: "type" :: Parser Text
      case ty of
        "text" -> Left <$> b .: "text"
        "tool_use" -> do
          tcid <- b .: "id"
          name <- b .: "name"
          -- Anthropic's @input@ is already a JSON object — no
          -- stringified-JSON ceremony like OpenAI requires.
          inp <- b .: "input"
          pure (Right (ToolCall tcid name inp))
        other -> fail $ "unknown content block type: " <> T.unpack other
