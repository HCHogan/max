module Max.LLM.ProtocolSpec (spec) where

import Data.Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Text (Text)
import Data.Vector qualified as V
import Max.LLM.Protocol (requestBodyFor)
import Max.LLM.Types (ChatMessage (..), ContentBlock (..))
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
spec = describe "prompt cache boundaries on the wire" $ do
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
