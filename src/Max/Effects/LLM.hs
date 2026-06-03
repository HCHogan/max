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

import Control.Exception (SomeException, try)
import Data.Aeson
import Data.Aeson.Types (Parser, parseEither)
import Data.ByteString.Lazy qualified as LBS
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Effectful
import Effectful.Dispatch.Dynamic (interpret, send)
import Effectful.Log
import Network.HTTP.Client
  ( Manager,
    RequestBody (RequestBodyLBS),
    Response,
    httpLbs,
    method,
    newManager,
    parseRequest,
    requestBody,
    requestHeaders,
    responseBody,
    responseStatus,
    responseTimeout,
    responseTimeoutMicro,
  )
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Network.HTTP.Types.Status (statusCode)

-- | A single named LLM endpoint.  Materialized from
-- @[llm.profiles.<name>]@ in TOML.
data LLMProfile = LLMProfile
  { -- | e.g. @https://api.deepseek.com/v1@.  We append @/chat/completions@.
    baseUrl :: !Text,
    apiKey :: !Text,
    -- | Model id; @deepseek-chat@, @gpt-4o-mini@, @qwen2.5:7b@, etc.
    model :: !Text,
    maxTokens :: !Int,
    temperature :: !Double,
    -- | HTTP timeout for one chat completion.  LLMs are slow, default 120.
    timeoutSeconds :: !Int
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
  | -- | Plain assistant text response.
    MsgAssistant !Text
  | -- | Assistant chose to call one or more tools.  The wire form has
    -- @content: null@ alongside the @tool_calls@ array.
    MsgAssistantToolCalls ![ToolCall]
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
    -- them and re-invokes 'chat' with the results appended.
    ToolCallsResp ![ToolCall]
  deriving stock (Show)

--------------------------------------------------------------------------------
-- JSON.

instance ToJSON ChatMessage where
  toJSON = \case
    MsgSystem c -> object ["role" .= ("system" :: Text), "content" .= c]
    MsgUser c -> object ["role" .= ("user" :: Text), "content" .= c]
    MsgAssistant c -> object ["role" .= ("assistant" :: Text), "content" .= c]
    MsgAssistantToolCalls tcs ->
      object
        [ "role" .= ("assistant" :: Text),
          "content" .= Null,
          "tool_calls" .= map encodeToolCall tcs
        ]
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
        case mTools of
          Just tcs | not (null tcs) -> MsgAssistantToolCalls <$> traverse parseToolCall tcs
          _ -> do
            mC <- o .:? "content"
            pure (MsgAssistant (case mC of Just c -> c; Nothing -> ""))
      r -> fail $ "unknown chat role: " <> T.unpack r

parseToolCall :: Value -> Parser ToolCall
parseToolCall = withObject "ToolCall" $ \o -> do
  cid <- o .: "id"
  fn <- o .: "function" :: Parser Object
  name <- fn .: "name"
  argsStr <- fn .: "arguments" :: Parser Text
  args <- case eitherDecode (LBS.fromStrict (TE.encodeUtf8 argsStr)) of
    Right v -> pure v
    Left e -> fail $ "decoding tool arguments JSON: " <> e
  pure (ToolCall cid name args)

--------------------------------------------------------------------------------
-- Effect.

data LLM :: Effect where
  Chat :: Text -> [ChatMessage] -> [ToolSpec] -> LLM m (Either Text ChatResponse)
  ListProfiles :: LLM m [Text]
  DefaultProfile :: LLM m Text

type instance DispatchOf LLM = Dynamic

-- | One 'Manager' shared across all profiles — they're all just HTTPS
-- endpoints, so we don't gain anything by pooling per host.
runLLM ::
  (Log :> es, IOE :> es) =>
  LLMRegistry ->
  Eff (LLM : es) a ->
  Eff es a
runLLM reg m = do
  mgr <- liftIO (newManager tlsManagerSettings)
  interpret
    ( \_ -> \case
        Chat name msgs tools -> case Map.lookup name reg.profiles of
          Nothing -> do
            logAttention "llm: unknown profile" $ object ["profile" .= name]
            pure $ Left ("unknown llm profile: " <> name)
          Just cfg -> do
            logInfo "llm: chat request" $
              object
                [ "msg_count" .= length msgs,
                  "tool_count" .= length tools,
                  "profile" .= name,
                  "model" .= cfg.model
                ]
            r <- liftIO (callChat mgr cfg msgs tools)
            case r of
              Left err ->
                logAttention "llm: error" $
                  object ["error" .= err, "profile" .= name]
              Right (ContentResp text) ->
                logInfo "llm: got content" $
                  object ["len" .= T.length text, "profile" .= name]
              Right (ToolCallsResp tcs) ->
                logInfo "llm: got tool_calls" $
                  object
                    [ "count" .= length tcs,
                      "names" .= map (.callName) tcs,
                      "profile" .= name
                    ]
            pure r
        ListProfiles -> pure (Map.keys reg.profiles)
        DefaultProfile -> pure reg.defaultName
    )
    m

chat :: LLM :> es => Text -> [ChatMessage] -> [ToolSpec] -> Eff es (Either Text ChatResponse)
chat name msgs tools = send (Chat name msgs tools)

listProfiles :: LLM :> es => Eff es [Text]
listProfiles = send ListProfiles

defaultProfile :: LLM :> es => Eff es Text
defaultProfile = send DefaultProfile

--------------------------------------------------------------------------------
-- HTTP.

-- | OpenAI-compatible @POST {baseUrl}/chat/completions@.
callChat :: Manager -> LLMProfile -> [ChatMessage] -> [ToolSpec] -> IO (Either Text ChatResponse)
callChat mgr cfg msgs tools = do
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
            [ "tools" .= map encodeToolSpec tools,
              "tool_choice" .= ("auto" :: Text)
            ]
      body = object (baseFields <> toolFields)
  req0 <- parseRequest (T.unpack (cfg.baseUrl <> "/chat/completions"))
  let req =
        req0
          { method = "POST",
            requestHeaders =
              [ ("Authorization", "Bearer " <> TE.encodeUtf8 cfg.apiKey),
                ("Content-Type", "application/json")
              ],
            requestBody = RequestBodyLBS (encode body),
            responseTimeout = responseTimeoutMicro (cfg.timeoutSeconds * 1_000_000)
          }
  eres <- try (httpLbs req mgr)
  case eres :: Either SomeException (Response LBS.ByteString) of
    Left e -> pure (Left ("http: " <> T.pack (show e)))
    Right resp ->
      let code = statusCode (responseStatus resp)
          rbody = responseBody resp
       in if code >= 400
            then
              pure $
                Left $
                  "HTTP "
                    <> T.pack (show code)
                    <> ": "
                    <> T.take 500 (TE.decodeUtf8Lenient (LBS.toStrict rbody))
            else case eitherDecode rbody of
              Left e -> pure (Left ("parse: " <> T.pack e))
              Right v -> case parseEither parseResponse v of
                Left e -> pure (Left ("extract: " <> T.pack e))
                Right r -> pure (Right r)

encodeToolSpec :: ToolSpec -> Value
encodeToolSpec t =
  object
    [ "type" .= ("function" :: Text),
      "function"
        .= object
          [ "name" .= t.specName,
            "description" .= t.specDescription,
            "parameters" .= t.specSchema
          ]
    ]

-- | Pull @choices[0].message@ off an OpenAI-style chat response and
-- return either the text or the tool-call list.  Treats an empty
-- @tool_calls@ array as "no calls".
parseResponse :: Value -> Parser ChatResponse
parseResponse = withObject "ChatResponse" $ \o -> do
  choices <- o .: "choices"
  case choices of
    (c : _) -> withObject "Choice" parseChoice c
    [] -> fail "no choices in response"
  where
    parseChoice c = do
      m <- c .: "message" :: Parser Object
      mTools <- m .:? "tool_calls"
      case mTools of
        Just tcs | not (null tcs) -> ToolCallsResp <$> traverse parseToolCall tcs
        _ -> do
          mC <- m .:? "content"
          case mC of
            Just c' -> pure (ContentResp c')
            Nothing -> fail "no content nor tool_calls in message"
