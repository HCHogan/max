-- | Pure wire encoders, response decoders and streamed-response reconstruction.
-- A single request body serves both actual transport and the call record.
module Max.LLM.Protocol
  ( requestBodyFor,
    parseResponseOpenAI,
    parseResponseAnthropic,
    parseResponseResponses,
    responsesFields,
    rebuildResponses,
    rebuildOpenAI,
    rebuildAnthropic,
    stripLeadingThink,
  )
where

import Control.Applicative ((<|>))
import Data.Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (Pair, Parser, parseMaybe)
import Data.ByteString.Lazy qualified as LBS
import Data.List (find)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Traversable (for)
import Data.Vector qualified as V
import Max.LLM.Stream (PartialCall (..), StreamAcc (..), accToolCalls)
import Max.LLM.Types
import Max.ModelCatalog.Internal (LLMProfile (..), Protocol (..))
import Max.Tool.Types (ToolSpec (..))

requestBodyFor :: LLMProfile -> [ChatMessage] -> [ToolSpec] -> Bool -> Value
requestBodyFor cfg msgs tools streaming =
  object $ case cfg.protocol of
    ProtocolOpenAI ->
      openAIFields cfg msgs tools
        <> (if streaming then streamFieldsOpenAI else ["stream" .= False])
    ProtocolAnthropic -> anthropicFields cfg msgs tools <> ["stream" .= streaming]
    ProtocolResponses -> responsesFields cfg msgs tools <> ["stream" .= streaming]

-- | Ask the OpenAI streaming endpoint to report usage, including cache hits.
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

openAIFields :: LLMProfile -> [ChatMessage] -> [ToolSpec] -> [Pair]
openAIFields cfg msgs tools =
  [ "model" .= cfg.model,
    "messages" .= msgs,
    "max_tokens" .= cfg.maxTokens
  ]
    <> temperatureField cfg
    <> effortFieldOpenAI cfg
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

-- | OpenAI wire shape: top-level @reasoning_effort@.  Absent = don't
-- send, same rationale as temperature.
effortFieldOpenAI :: LLMProfile -> [Pair]
effortFieldOpenAI cfg = case cfg.effort of
  Just e -> ["reasoning_effort" .= e]
  Nothing -> []

-- | Anthropic wire shape: @output_config.effort@ — nested, not
-- top-level (the top-level spelling is rejected).
effortFieldAnthropic :: LLMProfile -> [Pair]
effortFieldAnthropic cfg = case cfg.effort of
  Just e -> ["output_config" .= object ["effort" .= e]]
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

--------------------------------------------------------------------------------
-- OpenAI Responses API: POST {baseUrl}/responses.

responsesFields :: LLMProfile -> [ChatMessage] -> [ToolSpec] -> [Pair]
responsesFields cfg msgs tools =
  [ "model" .= cfg.model,
    "input" .= inputItems,
    "max_output_tokens" .= cfg.maxTokens,
    "store" .= False,
    "include" .= (["reasoning.encrypted_content"] :: [Text])
  ]
    <> ["instructions" .= i | Just i <- [instructions]]
    <> temperatureField cfg
    <> [f | Just e <- [cfg.effort], f <- ["reasoning" .= object ["effort" .= e]]]
    <> [ f
       | not (null tools),
         f <-
           [ "tools" .= map encodeToolSpecResponses tools,
             "tool_choice" .= ("auto" :: Text)
           ]
       ]
  where
    (instructions, inputItems) = responsesInput msgs

-- | Split the conversation into the request's @instructions@ (system
-- text) and @input@ items.  A 'MsgAssistantToolCalls' stores the
-- provider's whole @output@ array as its raw value, so replay splices
-- the array back in — reasoning items, encrypted content, function
-- calls, all byte-identical.
responsesInput :: [ChatMessage] -> (Maybe Text, [Value])
responsesInput msgs = (instructions, concatMap item msgs)
  where
    systems = [c | MsgSystem c <- msgs]
    instructions
      | null systems = Nothing
      | otherwise = Just (T.intercalate "\n\n" systems)
    item = \case
      MsgSystem _ -> []
      MsgUser c -> [object ["role" .= ("user" :: Text), "content" .= c]]
      MsgUserBlocks blocks ->
        [object ["role" .= ("user" :: Text), "content" .= map inputBlock blocks]]
      MsgAssistant c -> [object ["role" .= ("assistant" :: Text), "content" .= c]]
      MsgAssistantToolCalls raw _ -> case raw of
        Array xs -> V.toList xs
        v -> [v]
      MsgTool cid c ->
        [ object
            [ "type" .= ("function_call_output" :: Text),
              "call_id" .= cid,
              "output" .= c
            ]
        ]
    inputBlock = \case
      TextBlock t -> object ["type" .= ("input_text" :: Text), "text" .= t]
      ImageDataUrl u -> object ["type" .= ("input_image" :: Text), "image_url" .= u]
      -- No video input on this API; a marker beats a 400.
      VideoDataUrl _ -> object ["type" .= ("input_text" :: Text), "text" .= ("[video omitted]" :: Text)]

-- | Responses tools are flat — no @function@ wrapper.
encodeToolSpecResponses :: ToolSpec -> Value
encodeToolSpecResponses t =
  object
    [ "type" .= ("function" :: Text),
      "name" .= t.specName,
      "description" .= t.specDescription,
      "parameters" .= t.specSchema
    ]

-- | Walk the @output@ array: @function_call@ items become tool calls
-- (keyed by @call_id@ — that is what @function_call_output@ must echo),
-- @message@ items contribute their @output_text@.  When calls are
-- present the whole array is kept as the raw round-trip value.
parseResponseResponses :: Value -> Parser (ChatResponse, Maybe TokenUsage)
parseResponseResponses = withObject "Response" $ \o -> do
  outputs <- o .: "output" :: Parser [Value]
  mUsageV <- o .:? "usage"
  calls <- traverse parseFnCall [v | v <- outputs, itemType v == Just "function_call"]
  let text = T.intercalate "" (concatMap messageText outputs)
  resp <- case calls of
    [] | T.null (T.strip text) -> fail "no output_text nor function_call in output"
    [] -> pure (ContentResp text)
    tcs -> pure (ToolCallsResp (toJSON outputs) text tcs)
  pure (resp, parseMaybe parseUsageResponses =<< mUsageV)
  where
    itemType :: Value -> Maybe Text
    itemType = parseMaybe (withObject "item" (.: "type"))
    messageText v = fromMaybe [] $
      flip parseMaybe v $
        withObject "item" $ \i -> do
          ty <- i .: "type"
          if ty /= ("message" :: Text)
            then pure []
            else do
              content <- i .: "content" :: Parser [Object]
              fmap concat . for content $ \c -> do
                cty <- c .: "type"
                if cty == ("output_text" :: Text)
                  then (: []) <$> c .: "text"
                  else pure []
    parseFnCall = withObject "function_call" $ \i -> do
      cid <- i .: "call_id"
      name <- i .: "name"
      argsStr <- i .:? "arguments" :: Parser (Maybe Text)
      args <- case argsStr of
        Nothing -> pure (Object mempty)
        Just s | T.null (T.strip s) -> pure (Object mempty)
        Just s -> case eitherDecode (LBS.fromStrict (TE.encodeUtf8 s)) of
          Right v -> pure v
          Left e -> fail ("decoding function_call arguments: " <> e)
      pure (ToolCall cid name args)

parseUsageResponses :: Value -> Parser TokenUsage
parseUsageResponses = withObject "usage" $ \o -> do
  p <- o .: "input_tokens"
  c <- o .: "output_tokens"
  mDetails <- o .:? "input_tokens_details"
  cached <- case mDetails of
    Nothing -> pure Nothing
    Just d -> d .:? "cached_tokens"
  pure (TokenUsage p c cached)

-- | The terminal @response.completed@ frame carried the entire
-- response object, so rebuilding is just parsing it; a stream that
-- died first degrades to the accumulated text.
rebuildResponses :: StreamAcc -> ChatResponse
rebuildResponses acc =
  case parseMaybe parseResponseResponses acc.saMessage of
    Just (resp, _) -> resp
    Nothing -> ContentResp acc.saText

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

anthropicFields :: LLMProfile -> [ChatMessage] -> [ToolSpec] -> [Pair]
anthropicFields cfg msgs tools =
  [ "model" .= cfg.model,
    "max_tokens" .= cfg.maxTokens,
    "messages" .= map encodeAnthropicMsg (markLastForCache anthropicMsgs)
  ]
    <> temperatureField cfg
    <> effortFieldAnthropic cfg
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
