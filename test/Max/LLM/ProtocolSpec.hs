module Max.LLM.ProtocolSpec (spec) where

import Control.Monad (forM_)
import Data.Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (parseEither)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Vector qualified as V
import Max.LLM.Protocol
import Max.LLM.Stream (PartialCall (..), StreamAcc (..), emptyAcc)
import Max.LLM.Types (ChatMessage (..), ChatResponse (..), ContentBlock (..), assistantMessage)
import Max.ModelCatalog (LLMProfile (..), Protocol (..))
import Test.Hspec

profile :: Protocol -> Bool -> LLMProfile
profile protocol hints =
  LLMProfile
    { baseUrl = "http://localhost/v1",
      apiKey = "",
      model = "fixture",
      maxInputTokens = 100000,
      maxTokens = 1000,
      adaptiveOutput = False,
      attachmentReserve = 0,
      toolRoundReserve = 0,
      temperature = Nothing,
      effort = Nothing,
      timeoutSeconds = 60,
      protocol = protocol,
      multimodal = False,
      historyAsTurns = False,
      stream = False,
      promptCacheBreakpoints = hints,
      contextBudget = Nothing,
      visionLimits = Nothing,
      prices = Nothing
    }

marked :: [ChatMessage]
marked =
  [ MsgSystem "system",
    MsgUserBlocks [TextBlock "[episodes]\n", CacheBoundary, TextBlock "[recent messages]\nhi\n", CacheBoundary, TextBlock "[current message]\nq"]
  ]

field :: Text -> Value -> Maybe Value
field key = \case
  Object o -> KM.lookup (Key.fromText key) o
  _ -> Nothing

userContent :: Value -> Maybe Value
userContent body = case field "messages" body of
  Just (Array messages) -> case [m | m <- V.toList messages, field "role" m == Just "user"] of
    message : _ -> field "content" message
    [] -> Nothing
  _ -> Nothing

parts :: Maybe Value -> [Value]
parts = \case
  Just (Array xs) -> V.toList xs
  _ -> []

spec :: Spec
spec = describe "LLM wire encoding" $ do
  it "keeps volatile coordination outside the Anthropic cache boundary and host metadata off every wire" $ do
    let messages = [MsgSystem "rules", MsgUser "request", MsgAssistant "prior", MsgVolatile "other task is waiting"]
        encoded = requestBodyFor (profile ProtocolAnthropic True) messages [] False
        wire = parts (field "messages" encoded)
    length wire `shouldBe` 3
    field "cache_control" (last (parts (field "content" (wire !! 1)))) `shouldNotBe` Nothing
    field "content" (last wire) `shouldBe` Just (String "other task is waiting")
    field "volatile" (last wire) `shouldBe` Nothing
    forM_ [ProtocolOpenAI, ProtocolResponses] $ \protocol -> do
      let body = requestBodyFor (profile protocol False) messages [] False
          rows = parts (field (if protocol == ProtocolOpenAI then "messages" else "input") body)
      field "content" (last rows) `shouldBe` Just (String "other task is waiting")
      field "volatile" (last rows) `shouldBe` Nothing

  it "sends unmarked profiles the same plain string as an unsplit prompt" $
    userContent (requestBodyFor (profile ProtocolOpenAI False) marked [] False)
      `shouldBe` Just (String "[episodes]\n[recent messages]\nhi\n[current message]\nq")

  it "marks the stable parts as NInfer explicit breakpoints on the OpenAI protocol" $ do
    let content = parts (userContent (requestBodyFor (profile ProtocolOpenAI True) marked [] False))
    map (field "text") content `shouldBe` map (Just . String) ["[episodes]\n", "[recent messages]\nhi\n", "[current message]\nq"]
    map (field "prompt_cache_breakpoint") content `shouldBe` [Just (object ["mode" .= ("explicit" :: Text)]), Just (object ["mode" .= ("explicit" :: Text)]), Nothing]

  it "marks the stable parts with cache_control on the Anthropic protocol" $ do
    let content = parts (userContent (requestBodyFor (profile ProtocolAnthropic True) marked [] False))
    map (field "text") content `shouldBe` map (Just . String) ["[episodes]\n", "[recent messages]\nhi\n", "[current message]\nq"]
    map ((/= Nothing) . field "cache_control") content `shouldBe` [True, True, True]

  it "replays buffered and streamed OpenAI final reasoning without exposing it as answer text" $ do
    let raw = object ["role" .= ("assistant" :: Text), "content" .= ("<think>private</think>answer" :: Text), "reasoning_content" .= ("opaque" :: Text), "provider_extension" .= object ["signature" .= ("sig" :: Text)]]
        response = object ["choices" .= [object ["message" .= raw]]]
        streamed = rebuildOpenAI emptyAcc {saMessage = raw, saText = "<think>private</think>answer"}
    parsed <- either (fail . show) (pure . fst) (parseEither parseResponseOpenAI response)
    forM_ [parsed, streamed] $ \value -> do
      case value of
        ContentResp text -> text `shouldBe` "answer"
        other -> expectationFailure (show other)
      let request = requestBodyFor (profile ProtocolOpenAI False) [assistantMessage value, MsgUser "correction"] [] False
      take 1 (parts (field "messages" request)) `shouldBe` [raw]

  it "replays final Anthropic thinking signatures for buffered and streamed answers" $ do
    let thinking = object ["type" .= ("thinking" :: Text), "thinking" .= ("private" :: Text), "signature" .= ("opaque signature" :: Text)]
        answer = object ["type" .= ("text" :: Text), "text" .= ("answer" :: Text), "citations" .= ([] :: [Value])]
        blocks = [thinking, answer]
        raw = object ["role" .= ("assistant" :: Text), "content" .= blocks]
        streamed = rebuildAnthropic emptyAcc {saBlocks = Map.fromList (zip [0 ..] blocks), saText = "answer"}
    parsed <- either (fail . show) (pure . fst) (parseEither parseResponseAnthropic raw)
    forM_ [parsed, streamed] $ \value -> do
      case value of
        ContentResp text -> text `shouldBe` "answer"
        other -> expectationFailure (show other)
      let request = requestBodyFor (profile ProtocolAnthropic False) [assistantMessage value, MsgUser "correction"] [] False
      take 1 (parts (field "messages" request)) `shouldBe` [raw]

  it "splices final Responses reasoning and message items back in order" $ do
    let outputs = [object ["type" .= ("reasoning" :: Text), "encrypted_content" .= ("opaque" :: Text)], object ["type" .= ("message" :: Text), "role" .= ("assistant" :: Text), "id" .= ("msg_1" :: Text), "content" .= [object ["type" .= ("output_text" :: Text), "text" .= ("answer" :: Text), "annotations" .= ([] :: [Value])]]]]
        raw = object ["output" .= outputs]
    parsed <- either (fail . show) (pure . fst) (parseEither parseResponseResponses raw)
    forM_ [parsed, rebuildResponses emptyAcc {saMessage = raw}] $ \value -> do
      let request = requestBodyFor (profile ProtocolResponses False) [assistantMessage value, MsgUser "correction"] [] False
      take 2 (parts (field "input" request)) `shouldBe` outputs

  it "preserves an explicit empty tool_calls field on a streamed final answer" $ do
    let raw = object ["role" .= ("assistant" :: Text), "content" .= ("answer" :: Text), "tool_calls" .= ([] :: [Value])]
    toJSON (assistantMessage (rebuildOpenAI emptyAcc {saMessage = raw, saText = "answer"})) `shouldBe` raw

  it "does not replay an incomplete streamed call as part of a final answer" $ do
    let raw = object ["role" .= ("assistant" :: Text), "content" .= ("partial" :: Text), "tool_calls" .= [object ["id" .= ("bad" :: Text)]]]
        value = rebuildOpenAI emptyAcc {saMessage = raw, saText = "partial", saCalls = Map.singleton 0 (PartialCall "bad" "echo" "{")}
    field "tool_calls" (toJSON (assistantMessage value)) `shouldBe` Nothing
