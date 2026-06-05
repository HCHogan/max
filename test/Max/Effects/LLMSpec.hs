module Max.Effects.LLMSpec (spec) where

import Data.Aeson (Value (..), decode, eitherDecode, encode, object, (.=))
import Data.Aeson.KeyMap qualified as KM
import Data.Text (Text)
import Max.Effects.LLM (ChatMessage (..), ToolCall (..))
import Test.Hspec

-- | Round-tripping a single 'ChatMessage' through aeson should be
-- value-preserving — except for 'MsgAssistantToolCalls', whose
-- arguments are stringified on the wire (we re-encode them on
-- decode, so the parsed 'callArguments' is a parsed 'Value' again).
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

    it "MsgAssistantToolCalls preserves call ids/names/args + reasoning" $ do
      let tc = ToolCall "call_1" "web_search" (object ["q" .= ("haskell" :: Text)])
          m = MsgAssistantToolCalls (Just "let me search…") [tc]
      case roundTrip m of
        Right (MsgAssistantToolCalls mr tcs) -> do
          mr `shouldBe` Just "let me search…"
          case tcs of
            [tc'] -> do
              tc'.callId `shouldBe` "call_1"
              tc'.callName `shouldBe` "web_search"
              tc'.callArguments `shouldBe` object ["q" .= ("haskell" :: Text)]
            _ -> expectationFailure $ "expected 1 call, got: " <> show tcs
        other -> expectationFailure $ "bad round-trip: " <> show other

    it "MsgAssistantToolCalls without reasoning omits the field on encode" $ do
      let tc = ToolCall "call_1" "noop" (Object KM.empty)
          m = MsgAssistantToolCalls Nothing [tc]
          encoded = encode m
      case decode encoded :: Maybe Value of
        Just (Object o) -> KM.member "reasoning_content" o `shouldBe` False
        other -> expectationFailure $ "expected object, got: " <> show other

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

  describe "decode of incoming assistant message" $ do
    it "treats missing content as empty string" $ do
      let wire = object ["role" .= ("assistant" :: Text)]
      case eitherDecode (encode wire) of
        Right (MsgAssistant t) -> t `shouldBe` ""
        other -> expectationFailure $ "expected MsgAssistant \"\", got: " <> show other
