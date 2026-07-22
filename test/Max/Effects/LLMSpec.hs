module Max.Effects.LLMSpec (spec) where

import Data.Aeson (Value (..), decode, eitherDecode, encode, object, toJSON, (.=))
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (parseEither)
import Data.Text (Text)
import Data.Vector qualified as V
import Max.Effects.LLM
  ( ChatMessage (..),
    ChatResponse (..),
    ContentBlock (..),
    TokenUsage (..),
    ToolCall (..),
    parseResponseAnthropic,
    parseResponseOpenAI,
  )
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
        Right (ToolCallsResp raw [tc], _) -> do
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
        Right (ToolCallsResp raw [tc], _) -> do
          raw
            `shouldBe` object
              [ "role" .= ("assistant" :: Text),
                "content" .= blocks
              ]
          tc.callId `shouldBe` "t1"
        other -> expectationFailure $ "expected ToolCallsResp, got: " <> show other

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
