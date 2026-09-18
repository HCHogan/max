-- | Pure completion messages, responses, usage and archive codecs.
module Max.LLM.Types (ContentBlock (..), ChatMessage (..), ToolCall (..), ChatResponse (..), TokenUsage (..), parseToolCall) where

import Control.Applicative ((<|>))
import Data.Aeson
import Data.Aeson.Types (Parser)
import Data.ByteString.Lazy qualified as LBS
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Max.Http.Failure (ResponseFailure)

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
    -- raw provider message, including opaque reasoning, unchanged into the next
    -- tool round. The parsed calls are used for execution only.
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

-- | What the model decided this turn.
data ChatResponse
  = -- | A plain text answer.  The loop is done.
    ContentResp !Text
  | -- | Usable partial text, with an explicit transport failure. Never success.
    InterruptedResp !Text !ResponseFailure
  | -- | The model wants to call one or more tools.  Caller executes
    -- them, then appends results to the next request. Preserve the raw 'Value'
    -- in 'MsgAssistantToolCalls'; 'Text' contains any accompanying narration.
    ToolCallsResp !Value !Text ![ToolCall]
  deriving stock (Show)

-- | Provider-reported token usage for one completion.  Persisted via
-- the interpreter's 'UsageWriter' (see @llm_usage@) and logged, so
-- both the admin API and journalctl can reconstruct token spend.
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

instance FromJSON ContentBlock where
  parseJSON = withObject "ContentBlock" $ \o ->
    o .: "type" >>= \case
      "text" -> TextBlock <$> o .: "text"
      "video_url" -> VideoDataUrl <$> nestedUrl o "video_url"
      "image_url" -> ImageDataUrl <$> nestedUrl o "image_url"
      other -> fail ("unknown content block type: " <> T.unpack (other :: Text))
    where
      nestedUrl o key = o .: key >>= withObject "url wrapper" (.: "url")

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
      -- Text or blocks, dispatched on the shape the encoder produced.
      "user" ->
        o .: "content" >>= \case
          String text -> pure (MsgUser text)
          blocks@(Array _) -> MsgUserBlocks <$> parseJSON blocks
          _ -> fail "user content must be a string or an array of content blocks"
      "tool" -> MsgTool <$> o .: "tool_call_id" <*> o .: "content"
      "assistant" -> do
        mTools <- o .:? "tool_calls"
        case mTools of
          Just tcs | not (null tcs) -> do
            tcs' <- traverse parseToolCall tcs
            pure (MsgAssistantToolCalls (Object o) tcs')
          _ -> do
            mC <- o .:? "content"
            pure (MsgAssistant (fromMaybe "" mC))
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
