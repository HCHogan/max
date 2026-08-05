module Max.Effects.LLMSpec (spec) where

import Data.Aeson (Value (..), decode, eitherDecode, encode, object, toJSON, (.=))
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Key (Key)
import Data.Map.Strict qualified as Map
import Data.Aeson.Types (parseEither)
import Data.Text (Text, isPrefixOf)
import Data.Vector qualified as V
import Max.Effects.LLM
  ( ChatMessage (..),
    ChatResponse (..),
    ContentBlock (..),
    TokenUsage (..),
    ToolCall (..),
    parseResponseAnthropic,
    parseResponseOpenAI,
    parseResponseResponses,
    rebuildAnthropic,
    rebuildOpenAI,
    stripLeadingThink,
  )
import Max.LLM.Stream (PartialCall (..), StreamAcc (..), emptyAcc)
import Test.Hspec

-- | Round-tripping a single 'ChatMessage' through aeson should be
-- value-preserving.  'MsgAssistantToolCalls' carries the provider's
-- wire message verbatim, so its encode is exactly what came in.
roundTrip :: ChatMessage -> Either String ChatMessage
roundTrip m = eitherDecode (encode m)

-- | The OpenAI wire shape for one tool_call.  We assemble it by hand
-- so we can also test the malformed variants below.
toolCallWire :: Text -> Text -> Text -> Value
toolCallWire cid name argsJson =
  object
    [ "id" .= cid,
      "type" .= ("function" :: Text),
      "function"
        .= object
          [ "name" .= name,
            "arguments" .= argsJson
          ]
    ]

-- | Assistant-with-tool-calls message wire shape.
asstWithCalls :: [Value] -> Value
asstWithCalls calls =
  object
    [ "role" .= ("assistant" :: Text),
      "content" .= Null,
      "tool_calls" .= calls
    ]

spec :: Spec
spec = do
  streamingSpec
  responsesSpec
  describe "ChatMessage JSON round-trip" $ do
    it "MsgSystem" $ do
      let m = MsgSystem "you are a bot"
      case roundTrip m of
        Right (MsgSystem t) -> t `shouldBe` "you are a bot"
        other -> expectationFailure $ "bad round-trip: " <> show other

    it "MsgUser" $ do
      let m = MsgUser "hello"
      case roundTrip m of
        Right (MsgUser t) -> t `shouldBe` "hello"
        other -> expectationFailure $ "bad round-trip: " <> show other

    it "MsgAssistant" $ do
      let m = MsgAssistant "hi back"
      case roundTrip m of
        Right (MsgAssistant t) -> t `shouldBe` "hi back"
        other -> expectationFailure $ "bad round-trip: " <> show other

    it "MsgTool keeps tool_call_id and content" $ do
      let m = MsgTool "call_abc" "{\"ok\":true}"
      case roundTrip m of
        Right (MsgTool cid c) -> do
          cid `shouldBe` "call_abc"
          c `shouldBe` "{\"ok\":true}"
        other -> expectationFailure $ "bad round-trip: " <> show other

    it "MsgAssistantToolCalls re-encodes the provider message verbatim" $ do
      -- Whatever fields/structure the provider sent (known or not)
      -- must come back byte-identical — thinking output round-trips
      -- in the provider's own shape.
      let wire =
            object
              [ "role" .= ("assistant" :: Text),
                "content" .= Null,
                "reasoning_content" .= ("let me search…" :: Text),
                "reasoning_details" .= [object ["type" .= ("reasoning.text" :: Text)]],
                "tool_calls" .= [toolCallWire "call_1" "web_search" "{\"q\":\"haskell\"}"]
              ]
      case eitherDecode (encode wire) of
        Right m@(MsgAssistantToolCalls raw tcs) -> do
          raw `shouldBe` wire
          (decode (encode m) :: Maybe Value) `shouldBe` Just wire
          case tcs of
            [tc'] -> do
              tc'.callId `shouldBe` "call_1"
              tc'.callName `shouldBe` "web_search"
              tc'.callArguments `shouldBe` object ["q" .= ("haskell" :: Text)]
            _ -> expectationFailure $ "expected 1 call, got: " <> show tcs
        other -> expectationFailure $ "bad decode: " <> show other

  describe "tool_call argument parsing tolerance" $ do
    it "absent arguments → empty object" $ do
      let wire =
            object
              [ "id" .= ("c1" :: Text),
                "type" .= ("function" :: Text),
                "function" .= object ["name" .= ("noop" :: Text)]
              ]
      case eitherDecode (encode (asstWithCalls [wire])) of
        Right (MsgAssistantToolCalls _ [tc]) ->
          tc.callArguments `shouldBe` Object KM.empty
        other -> expectationFailure $ "expected one tool call, got: " <> show other

    it "empty-string arguments → empty object" $ do
      let wire = toolCallWire "c1" "noop" "   "
      case eitherDecode (encode (asstWithCalls [wire])) of
        Right (MsgAssistantToolCalls _ [tc]) ->
          tc.callArguments `shouldBe` Object KM.empty
        other -> expectationFailure $ "expected one tool call, got: " <> show other

    it "name at top level (proxy-mangled) is accepted as a fallback" $ do
      -- Mimics the how88.top bug: name moved out of `function`.
      let wire =
            object
              [ "id" .= ("c1" :: Text),
                "type" .= ("function" :: Text),
                "name" .= ("web_search" :: Text), -- top-level
                "function" .= object ["arguments" .= ("{}" :: Text)]
              ]
      case eitherDecode (encode (asstWithCalls [wire])) of
        Right (MsgAssistantToolCalls _ [tc]) -> tc.callName `shouldBe` "web_search"
        other -> expectationFailure $ "expected one tool call, got: " <> show other

    it "name nowhere → parse failure" $ do
      let wire =
            object
              [ "id" .= ("c1" :: Text),
                "type" .= ("function" :: Text),
                "function" .= object ["arguments" .= ("{}" :: Text)]
              ]
      case eitherDecode (encode (asstWithCalls [wire])) :: Either String ChatMessage of
        Left _ -> pure () -- expected
        Right ok -> expectationFailure $ "expected failure, got: " <> show ok

  describe "tool-call responses carry the provider message verbatim" $ do
    it "OpenAI: choices[0].message rides along raw, unknown fields included" $ do
      let msg =
            object
              [ "role" .= ("assistant" :: Text),
                "content" .= Null,
                "reasoning" .= ("thinking hard…" :: Text),
                "some_future_field" .= object ["x" .= (1 :: Int)],
                "tool_calls" .= [toolCallWire "c1" "web_search" "{}"]
              ]
          v = object ["choices" .= [object ["message" .= msg]]]
      case parseEither parseResponseOpenAI v of
        Right (ToolCallsResp raw _ [tc], _) -> do
          raw `shouldBe` msg
          tc.callName `shouldBe` "web_search"
        other -> expectationFailure $ "expected ToolCallsResp, got: " <> show other

    it "Anthropic: thinking + text + tool_use blocks all survive in raw" $ do
      let blocks =
            [ object
                [ "type" .= ("thinking" :: Text),
                  "thinking" .= ("let me think" :: Text),
                  "signature" .= ("sig123" :: Text)
                ],
              object ["type" .= ("text" :: Text), "text" .= ("calling a tool" :: Text)],
              object
                [ "type" .= ("tool_use" :: Text),
                  "id" .= ("t1" :: Text),
                  "name" .= ("web_search" :: Text),
                  "input" .= object ["q" .= ("hi" :: Text)]
                ]
            ]
          v = object ["content" .= blocks]
      case parseEither parseResponseAnthropic v of
        Right (ToolCallsResp raw _ [tc], _) -> do
          raw
            `shouldBe` object
              [ "role" .= ("assistant" :: Text),
                "content" .= blocks
              ]
          tc.callId `shouldBe` "t1"
        other -> expectationFailure $ "expected ToolCallsResp, got: " <> show other

  -- Both wire formats let one assistant message carry text *and* tool
  -- calls, and Claude narrates that way constantly.  That text used to
  -- be dropped on the floor; it is the progress line the user would
  -- otherwise wait through in silence.
  describe "narration alongside tool calls" $ do
    it "OpenAI: keeps content when tool_calls are also present" $ do
      let msg =
            object
              [ "role" .= ("assistant" :: Text),
                "content" .= ("我先查一下这个视频" :: Text),
                "tool_calls" .= [toolCallWire "c1" "view_bilibili" "{}"]
              ]
          v = object ["choices" .= [object ["message" .= msg]]]
      case parseEither parseResponseOpenAI v of
        Right (ToolCallsResp _ narration _, _) -> narration `shouldBe` "我先查一下这个视频"
        other -> expectationFailure $ "expected ToolCallsResp, got: " <> show other

    it "OpenAI: narration is empty when the model went straight to the call" $ do
      let msg =
            object
              [ "role" .= ("assistant" :: Text),
                "content" .= Null,
                "tool_calls" .= [toolCallWire "c1" "view_bilibili" "{}"]
              ]
          v = object ["choices" .= [object ["message" .= msg]]]
      case parseEither parseResponseOpenAI v of
        Right (ToolCallsResp _ narration _, _) -> narration `shouldBe` ""
        other -> expectationFailure $ "expected ToolCallsResp, got: " <> show other

    it "Anthropic: concatenates text blocks that precede a tool_use" $ do
      let v =
            object
              [ "content"
                  .= [ object ["type" .= ("text" :: Text), "text" .= ("先看看" :: Text)],
                       object ["type" .= ("text" :: Text), "text" .= ("再说" :: Text)],
                       object
                         [ "type" .= ("tool_use" :: Text),
                           "id" .= ("t1" :: Text),
                           "name" .= ("web_search" :: Text),
                           "input" .= object []
                         ]
                     ]
              ]
      case parseEither parseResponseAnthropic v of
        Right (ToolCallsResp _ narration _, _) -> narration `shouldBe` "先看看再说"
        other -> expectationFailure $ "expected ToolCallsResp, got: " <> show other

    it "Anthropic: thinking blocks are not narration" $ do
      let v =
            object
              [ "content"
                  .= [ object
                         [ "type" .= ("thinking" :: Text),
                           "thinking" .= ("internal" :: Text),
                           "signature" .= ("s" :: Text)
                         ],
                       object
                         [ "type" .= ("tool_use" :: Text),
                           "id" .= ("t1" :: Text),
                           "name" .= ("web_search" :: Text),
                           "input" .= object []
                         ]
                     ]
              ]
      case parseEither parseResponseAnthropic v of
        Right (ToolCallsResp _ narration _, _) -> narration `shouldBe` ""
        other -> expectationFailure $ "expected ToolCallsResp, got: " <> show other

  describe "tool-call responses, continued" $ do
    it "Anthropic: unknown block types don't fail a text response" $ do
      let v =
            object
              [ "content"
                  .= [ object ["type" .= ("thinking" :: Text), "thinking" .= ("hm" :: Text)],
                       object ["type" .= ("text" :: Text), "text" .= ("hi" :: Text)]
                     ]
              ]
      case parseEither parseResponseAnthropic v of
        Right (ContentResp t, _) -> t `shouldBe` "hi"
        other -> expectationFailure $ "expected ContentResp, got: " <> show other

  describe "inline <think> stripping (OpenAI content)" $ do
    let respWith content =
          object
            [ "choices"
                .= [ object
                       ["message" .= object ["role" .= ("assistant" :: Text), "content" .= (content :: Text)]]
                   ]
            ]
    it "strips a leading think block and surrounding whitespace" $ do
      case parseEither parseResponseOpenAI (respWith "  <think>盐溶于水…</think>\n\n24斤。") of
        Right (ContentResp t, _) -> t `shouldBe` "24斤。"
        other -> expectationFailure $ "got: " <> show other
    it "an unclosed think block (truncated mid-think) strips to empty" $ do
      case parseEither parseResponseOpenAI (respWith "<think>反正就是在想") of
        Right (ContentResp t, _) -> t `shouldBe` ""
        other -> expectationFailure $ "got: " <> show other
    it "content without a think block passes through untouched" $ do
      case parseEither parseResponseOpenAI (respWith "直接回答，<think> 出现在中间不动它") of
        Right (ContentResp t, _) -> t `shouldBe` "直接回答，<think> 出现在中间不动它"
        other -> expectationFailure $ "got: " <> show other

  describe "usage extraction (OpenAI shape)" $ do
    let openaiResp usage =
          object $
            [ "choices"
                .= [ object
                       ["message" .= object ["role" .= ("assistant" :: Text), "content" .= ("hi" :: Text)]]
                   ]
            ]
              <> usage

    it "plain prompt/completion tokens" $ do
      let v = openaiResp ["usage" .= object ["prompt_tokens" .= (120 :: Int), "completion_tokens" .= (30 :: Int)]]
      case parseEither parseResponseOpenAI v of
        Right (ContentResp _, Just u) ->
          u `shouldBe` TokenUsage 120 30 Nothing
        other -> expectationFailure $ "expected usage, got: " <> show other

    it "DeepSeek prompt_cache_hit_tokens lands in cached" $ do
      let v =
            openaiResp
              [ "usage"
                  .= object
                    [ "prompt_tokens" .= (120 :: Int),
                      "completion_tokens" .= (30 :: Int),
                      "prompt_cache_hit_tokens" .= (100 :: Int)
                    ]
              ]
      case parseEither parseResponseOpenAI v of
        Right (_, Just u) -> u.usageCachedPrompt `shouldBe` Just 100
        other -> expectationFailure $ "expected usage, got: " <> show other

    it "OpenAI prompt_tokens_details.cached_tokens lands in cached" $ do
      let v =
            openaiResp
              [ "usage"
                  .= object
                    [ "prompt_tokens" .= (120 :: Int),
                      "completion_tokens" .= (30 :: Int),
                      "prompt_tokens_details" .= object ["cached_tokens" .= (64 :: Int)]
                    ]
              ]
      case parseEither parseResponseOpenAI v of
        Right (_, Just u) -> u.usageCachedPrompt `shouldBe` Just 64
        other -> expectationFailure $ "expected usage, got: " <> show other

    it "absent usage → Nothing, response still parses" $ do
      case parseEither parseResponseOpenAI (openaiResp []) of
        Right (ContentResp t, Nothing) -> t `shouldBe` "hi"
        other -> expectationFailure $ "expected no usage, got: " <> show other

    it "mangled usage → Nothing, response still parses" $ do
      let v = openaiResp ["usage" .= object ["prompt_tokens" .= ("what" :: Text)]]
      case parseEither parseResponseOpenAI v of
        Right (ContentResp _, Nothing) -> pure ()
        other -> expectationFailure $ "expected lenient Nothing, got: " <> show other

  describe "usage extraction (Anthropic shape)" $ do
    it "input/output/cache_read tokens" $ do
      let v =
            object
              [ "content" .= [object ["type" .= ("text" :: Text), "text" .= ("hi" :: Text)]],
                "usage"
                  .= object
                    [ "input_tokens" .= (200 :: Int),
                      "output_tokens" .= (50 :: Int),
                      "cache_read_input_tokens" .= (180 :: Int)
                    ]
              ]
      case parseEither parseResponseAnthropic v of
        Right (ContentResp _, Just u) ->
          u `shouldBe` TokenUsage 200 50 (Just 180)
        other -> expectationFailure $ "expected usage, got: " <> show other

    it "absent usage → Nothing, response still parses" $ do
      let v = object ["content" .= [object ["type" .= ("text" :: Text), "text" .= ("hi" :: Text)]]]
      case parseEither parseResponseAnthropic v of
        Right (ContentResp t, Nothing) -> t `shouldBe` "hi"
        other -> expectationFailure $ "expected no usage, got: " <> show other

  describe "decode of incoming assistant message" $ do
    it "treats missing content as empty string" $ do
      let wire = object ["role" .= ("assistant" :: Text)]
      case eitherDecode (encode wire) of
        Right (MsgAssistant t) -> t `shouldBe` ""
        other -> expectationFailure $ "expected MsgAssistant \"\", got: " <> show other

  describe "Multimodal MsgUserBlocks encoding" $ do
    it "encodes a text-only block as the text-only OpenAI shape" $ do
      let m = MsgUserBlocks [TextBlock "hi"]
      case decode (encode m) :: Maybe Value of
        Just (Object o) -> do
          KM.lookup "role" o `shouldBe` Just (toJSON ("user" :: Text))
          case KM.lookup "content" o of
            Just (Array _) -> pure () -- array form is fine even for a single text block
            other -> expectationFailure $ "expected array content, got: " <> show other
        other -> expectationFailure $ "expected object, got: " <> show other

    it "encodes text + image as an array of typed blocks" $ do
      let m =
            MsgUserBlocks
              [ TextBlock "describe this",
                ImageDataUrl "data:image/png;base64,AAAA"
              ]
      case decode (encode m) :: Maybe Value of
        Just (Object o) -> case KM.lookup "content" o of
          Just (Array arr) -> do
            length arr `shouldBe` 2
            -- text block
            case arr V.!? 0 of
              Just (Object t) -> do
                KM.lookup "type" t `shouldBe` Just (toJSON ("text" :: Text))
                KM.lookup "text" t `shouldBe` Just (toJSON ("describe this" :: Text))
              other -> expectationFailure $ "block 0: " <> show other
            -- image_url block (OpenAI-compat shape)
            case arr V.!? 1 of
              Just (Object i) -> do
                KM.lookup "type" i `shouldBe` Just (toJSON ("image_url" :: Text))
                case KM.lookup "image_url" i of
                  Just (Object u) ->
                    KM.lookup "url" u
                      `shouldBe` Just (toJSON ("data:image/png;base64,AAAA" :: Text))
                  other -> expectationFailure $ "image_url: " <> show other
              other -> expectationFailure $ "block 1: " <> show other
          other -> expectationFailure $ "content: " <> show other
        other -> expectationFailure $ "object: " <> show other

    it "encodes a video block with the video_url extension shape" $ do
      let m = MsgUserBlocks [VideoDataUrl "data:video/mp4;base64,BBBB"]
      case decode (encode m) :: Maybe Value of
        Just (Object o) -> case KM.lookup "content" o of
          Just (Array arr) -> case arr V.!? 0 of
            Just (Object v) -> do
              KM.lookup "type" v `shouldBe` Just (toJSON ("video_url" :: Text))
              case KM.lookup "video_url" v of
                Just (Object u) ->
                  KM.lookup "url" u
                    `shouldBe` Just (toJSON ("data:video/mp4;base64,BBBB" :: Text))
                other -> expectationFailure $ "video_url: " <> show other
            other -> expectationFailure $ "block 0: " <> show other
          other -> expectationFailure $ "content: " <> show other
        other -> expectationFailure $ "object: " <> show other

--------------------------------------------------------------------------------
-- Streaming reconstruction.
--
-- A streamed call never sees the provider's assistant message; it sees
-- deltas and has to rebuild one.  The rebuild is what goes back on the
-- next request, so if it is wrong the failure is a 400 two turns later
-- — far from the cause.  These pin the shape.

streamAcc :: Text -> Value -> [(Int, PartialCall)] -> StreamAcc
streamAcc text message calls =
  emptyAcc
    { saText = text,
      saMessage = message,
      saCalls = Map.fromList calls
    }

-- | An Anthropic accumulator: content blocks as the provider opened
-- them, plus whatever tool arguments streamed in.
blockAcc :: Text -> [(Int, Value)] -> [(Int, PartialCall)] -> StreamAcc
blockAcc text blocks calls =
  emptyAcc
    { saText = text,
      saBlocks = Map.fromList blocks,
      saCalls = Map.fromList calls
    }

-- | Follow the same path a real reply takes: rebuild, then encode as
-- 'MsgAssistantToolCalls' would.
wireOf :: ChatResponse -> Maybe Value
wireOf (ToolCallsResp raw _ _) = Just raw
wireOf _ = Nothing

streamingSpec :: Spec
streamingSpec = do
  describe "rebuildOpenAI" $ do
    it "returns plain content when no call arrived" $
      case rebuildOpenAI (streamAcc "上升沿圆角" (Object mempty) []) of
        ContentResp t -> t `shouldBe` "上升沿圆角"
        other -> expectationFailure ("expected content: " <> show other)

    -- The reconstructed message has to parse back as the same thing,
    -- because that is literally what happens: it is appended to the
    -- conversation and re-sent.
    it "round-trips through the ChatMessage parser" $ do
      let acc =
            streamAcc
              "我查一下"
              (object ["role" .= ("assistant" :: Text), "content" .= ("我查一下" :: Text)])
              [(0, PartialCall "call_a" "web_search" "{\"q\":\"探头\"}")]
      case rebuildOpenAI acc of
        r@(ToolCallsResp _ narration tcs) -> do
          narration `shouldBe` "我查一下"
          map (\t -> (t.callId, t.callName)) tcs `shouldBe` [("call_a", "web_search")]
          case wireOf r of
            Just raw -> roundTrip (MsgAssistantToolCalls raw tcs) `shouldSatisfy` isRight
            Nothing -> expectationFailure "no raw message"
        other -> expectationFailure ("expected tool calls: " <> show other)

    -- The replay is read off the merged message, not re-derived from
    -- the handful of fields we model, so a provider field we know
    -- nothing about still goes back.  DeepSeek's reasoning_content is
    -- the one that bites (it 400s without it); vendor_extra stands in
    -- for every field we haven't met yet.
    it "carries every field the wire sent back into the replay" $ do
      let acc =
            streamAcc
              "好"
              ( object
                  [ "role" .= ("assistant" :: Text),
                    "reasoning_content" .= ("先想想" :: Text),
                    "vendor_extra" .= ("keep me" :: Text)
                  ]
              )
              [(0, PartialCall "c" "f" "{}")]
      case wireOf (rebuildOpenAI acc) of
        Just (Object o) -> do
          KM.lookup "reasoning_content" o `shouldBe` Just (String "先想想")
          KM.lookup "vendor_extra" o `shouldBe` Just (String "keep me")
        other -> expectationFailure ("expected an object: " <> show other)

    it "supplies role when a gateway never sent one" $
      case wireOf (rebuildOpenAI (streamAcc "好" (Object mempty) [(0, PartialCall "c" "f" "{}")])) of
        Just (Object o) -> KM.lookup "role" o `shouldBe` Just (String "assistant")
        other -> expectationFailure ("expected an object: " <> show other)

    -- Argument fragments are individually invalid JSON, so "didn't
    -- parse" means "didn't finish arriving".  Executing that on a guess
    -- is how a tool gets called with half its arguments.
    it "drops a call whose arguments never finished arriving" $
      case rebuildOpenAI (streamAcc "" (Object mempty) [(0, PartialCall "c" "f" "{\"q\":")]) of
        ContentResp t -> t `shouldBe` ""
        other -> expectationFailure ("expected the call to be dropped: " <> show other)

    -- Replaying a call we never ran would leave the provider waiting
    -- for a tool result that can't exist, so tool_calls comes from what
    -- we execute — not from the merged message, which still holds the
    -- broken fragment.
    it "replays only the calls it actually executed" $ do
      let acc =
            streamAcc
              ""
              (object ["tool_calls" .= [object ["id" .= ("stale" :: Text)]]])
              [(0, PartialCall "good" "f" "{}")]
      case wireOf (rebuildOpenAI acc) of
        Just (Object o) -> case KM.lookup "tool_calls" o of
          Just (Array cs) ->
            [fieldText "id" c | c <- V.toList cs] `shouldBe` [Just "good"]
          other -> expectationFailure ("expected tool_calls: " <> show other)
        other -> expectationFailure ("expected an object: " <> show other)

    it "treats absent arguments as an empty object" $
      case rebuildOpenAI (streamAcc "" (Object mempty) [(0, PartialCall "c" "no_args" "")]) of
        ToolCallsResp _ _ [tc] -> tc.callArguments `shouldBe` Object mempty
        other -> expectationFailure ("expected one call: " <> show other)

  describe "rebuildAnthropic" $ do
    it "puts the blocks back in wire order" $
      case wireOf
        ( rebuildAnthropic
            ( blockAcc
                "我看一眼"
                [ (0, object ["type" .= ("text" :: Text), "text" .= ("我看一眼" :: Text)]),
                  (1, object ["type" .= ("tool_use" :: Text), "id" .= ("toolu_x" :: Text), "name" .= ("view_image" :: Text)])
                ]
                [(1, PartialCall "toolu_x" "view_image" "{\"id\":7405}")]
            )
        ) of
        Just (Object o) -> case KM.lookup "content" o of
          Just (Array blocks) ->
            [fieldText "type" b | b <- V.toList blocks] `shouldBe` [Just "text", Just "tool_use"]
          other -> expectationFailure ("expected a content array: " <> show other)
        other -> expectationFailure ("expected an object: " <> show other)

    -- The one that used to be impossible.  A thinking block replays
    -- with its signature, which the API streams as signature_delta
    -- precisely so a client can rebuild the block; without it the
    -- replayed turn is rejected.
    it "replays a thinking block with its signature intact" $ do
      let acc =
            blockAcc
              "答案是 21"
              [ ( 0,
                  object
                    [ "type" .= ("thinking" :: Text),
                      "thinking" .= ("用辗转相除" :: Text),
                      "signature" .= ("EqQBCgIYAhIM" :: Text)
                    ]
                ),
                (1, object ["type" .= ("tool_use" :: Text), "id" .= ("t1" :: Text), "name" .= ("f" :: Text)])
              ]
              [(1, PartialCall "t1" "f" "{}")]
      case wireOf (rebuildAnthropic acc) of
        Just (Object o) -> case KM.lookup "content" o of
          Just (Array blocks) -> case V.toList blocks of
            (Object t : _) -> do
              KM.lookup "thinking" t `shouldBe` Just (String "用辗转相除")
              KM.lookup "signature" t `shouldBe` Just (String "EqQBCgIYAhIM")
            other -> expectationFailure ("expected a thinking block: " <> show other)
          other -> expectationFailure ("expected a content array: " <> show other)
        other -> expectationFailure ("expected an object: " <> show other)

    it "fills a tool_use block's input from the accumulated arguments" $
      case wireOf
        ( rebuildAnthropic
            ( blockAcc
                ""
                [(0, object ["type" .= ("tool_use" :: Text), "id" .= ("t1" :: Text), "name" .= ("view_image" :: Text)])]
                [(0, PartialCall "t1" "view_image" "{\"id\":7405}")]
            )
        ) of
        Just (Object o) -> case KM.lookup "content" o of
          Just (Array blocks) -> case V.toList blocks of
            [Object b] -> KM.lookup "input" b `shouldBe` Just (object ["id" .= (7405 :: Int)])
            other -> expectationFailure ("expected one block: " <> show other)
          other -> expectationFailure ("expected a content array: " <> show other)
        other -> expectationFailure ("expected an object: " <> show other)

  -- Models that inline reasoning (MiniMax, GLM) open with a <think>
  -- block.  Streaming it out would put the monologue in the group, so
  -- the sink only ever sees post-strip text — and an unclosed block
  -- strips to nothing rather than to its contents.
  describe "stripLeadingThink, as the stream sees it" $ do
    it "yields nothing while the block is still open" $
      stripLeadingThink "<think>先看看用户在问什么\n\n然后" `shouldBe` ""

    it "yields only what follows once the block closes" $
      stripLeadingThink "<think>想好了</think>\n\n上升沿圆角" `shouldBe` "上升沿圆角"

    -- Monotone: what the sink released earlier stays a prefix of what
    -- it sees later, which is what makes 'sentPrefix' arithmetic valid.
    it "grows by appending as more text arrives" $ do
      let steps = ["<think>a</think>答案", "<think>a</think>答案是", "<think>a</think>答案是这个"]
          outs = map stripLeadingThink steps
      zip outs (drop 1 outs) `shouldSatisfy` all (uncurry isPrefixOf)

fieldText :: Key -> Value -> Maybe Text
fieldText k (Object o) = case KM.lookup k o of
  Just (String t) -> Just t
  _ -> Nothing
fieldText _ _ = Nothing

isRight :: Either a b -> Bool
isRight = either (const False) (const True)

--------------------------------------------------------------------------------
-- Responses API (GPT-5.x).

responsesSpec :: Spec
responsesSpec = describe "Responses API parsing" $ do
  it "reads a text-only response with usage (cached tokens included)" $ do
    let v =
          object
            [ "output"
                .= [ object
                       [ "type" .= ("reasoning" :: Text),
                         "encrypted_content" .= ("opaque" :: Text)
                       ],
                     object
                       [ "type" .= ("message" :: Text),
                         "role" .= ("assistant" :: Text),
                         "content"
                           .= [object ["type" .= ("output_text" :: Text), "text" .= ("你好" :: Text)]]
                       ]
                   ],
              "usage"
                .= object
                  [ "input_tokens" .= (100 :: Int),
                    "output_tokens" .= (7 :: Int),
                    "input_tokens_details" .= object ["cached_tokens" .= (64 :: Int)]
                  ]
            ]
    case parseEither parseResponseResponses v of
      Right (ContentResp t, Just u) -> do
        t `shouldBe` "你好"
        (u.usagePrompt, u.usageCompletion, u.usageCachedPrompt) `shouldBe` (100, 7, Just 64)
      other -> expectationFailure ("unexpected: " <> show other)

  -- The whole output array is the raw round-trip value: reasoning items
  -- (encrypted content included) must replay verbatim, and call_id is
  -- what function_call_output has to echo.
  it "keeps the full output array raw and keys calls by call_id" $ do
    let reasoning =
          object ["type" .= ("reasoning" :: Text), "encrypted_content" .= ("blob" :: Text)]
        fnCall =
          object
            [ "type" .= ("function_call" :: Text),
              "id" .= ("fc_item_9" :: Text),
              "call_id" .= ("call_abc" :: Text),
              "name" .= ("get_weather" :: Text),
              "arguments" .= ("{\"city\":\"Tokyo\"}" :: Text)
            ]
        v = object ["output" .= [reasoning, fnCall]]
    case parseEither parseResponseResponses v of
      Right (ToolCallsResp raw narration [tc], Nothing) -> do
        raw `shouldBe` toJSON [reasoning, fnCall]
        narration `shouldBe` ""
        tc.callId `shouldBe` "call_abc"
        tc.callName `shouldBe` "get_weather"
      other -> expectationFailure ("unexpected: " <> show other)

  it "empty arguments default to {}" $ do
    let v =
          object
            [ "output"
                .= [ object
                       [ "type" .= ("function_call" :: Text),
                         "call_id" .= ("call_1" :: Text),
                         "name" .= ("poke" :: Text)
                       ]
                   ]
            ]
    case parseEither parseResponseResponses v of
      Right (ToolCallsResp _ _ [tc], _) -> tc.callArguments `shouldBe` object []
      other -> expectationFailure ("unexpected: " <> show other)
