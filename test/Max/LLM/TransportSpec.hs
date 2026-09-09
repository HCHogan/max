module Max.LLM.TransportSpec (spec) where

import Control.Exception (throwIO)
import Data.Aeson (Value (..), eitherDecodeStrict', object, toJSON, (.=))
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as B8
import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Data.Vector qualified as V
import Effectful (runEff)
import Effectful.Log (runLog)
import Log (LogLevel (LogAttention))
import Max.Config (AppConfig (..), loadConfig)
import Max.Effects.LLM
import Max.Http.Failure (ResponseFailure (..), TransportFailure (..))
import Max.HttpRuntime (httpRuntimeFromManagers)
import Max.LLM.Failure (retryableLLMFailure)
import Max.Log (ColorMode (ColorNever), withCompactLogger)
import Max.ModelCatalog (defaultModelName)
import Network.HTTP.Client (Manager, ManagerSettings (..), defaultManagerSettings, makeConnection, newManager)
import System.Environment (withArgs)
import System.IO (hClose, hPutStr)
import System.IO.Temp (withSystemTempFile)
import Test.Hspec

spec :: Spec
spec = describe "LLM transport and call observation" $ do
  mapM_ protocolSpec ["openai", "anthropic", "responses"]
  mapM_ steeringSpec ["openai", "anthropic", "responses"]
  it "does not fail a completed provider call when usage or call recording fails" $
    withFixture "openai" False $ \config -> do
      written <- newIORef BS.empty
      manager <- recordingManager (wireResponse "openai" False) written
      let runtime = httpRuntimeFromManagers manager manager manager
      result <- withCompactLogger ColorNever Nothing $ \logger ->
        runEff
          . runLog "llm-wire-test" logger LogAttention
          . runLLM runtime (\_ _ _ -> throwIO (userError "fixture usage write")) (\_ -> throwIO (userError "fixture call write")) config.llm
          $ chat callContext (defaultModelName config.llm) [MsgUser "hello"] []
      result `shouldSatisfy` completed
  mapM_
    ( \streaming -> it ("preserves 4xx as a permanent structured failure with stream=" <> show streaming) $
        withFixture "openai" streaming $ \config -> do
          written <- newIORef BS.empty
          manager <- recordingManager (rawResponse 400 "upstream provider timeout HTTP 503") written
          let runtime = httpRuntimeFromManagers manager manager manager
          result <- withCompactLogger ColorNever Nothing $ \logger ->
            runEff
              . runLog "llm-wire-test" logger LogAttention
              . runLLM runtime (\_ _ _ -> pure ()) (\_ -> pure ()) config.llm
              $ chatStreaming callContext (defaultModelName config.llm) [MsgUser "hello"] [] (\_ -> pure ())
          case result of
            Left failure@(LLMResponseFailure (ResponseTransport (HttpStatusFailure 400 _ _ _))) -> retryableLLMFailure failure `shouldBe` False
            _ -> expectationFailure ("unexpected failure: " <> show result)
    )
    [False, True]
  it "retains a buffered temporary status after transport retries are exhausted" $
    withFixture "openai" False $ \config -> do
      written <- newIORef BS.empty
      manager <- recordingManager (rawResponse 503 "busy") written
      let runtime = httpRuntimeFromManagers manager manager manager
      result <- withCompactLogger ColorNever Nothing $ \logger ->
        runEff
          . runLog "llm-wire-test" logger LogAttention
          . runLLM runtime (\_ _ _ -> pure ()) (\_ -> pure ()) config.llm
          $ chat callContext (defaultModelName config.llm) [MsgUser "hello"] []
      case result of
        Left failure@(LLMResponseFailure (ResponseTransport (HttpStatusFailure 503 _ _ _))) -> retryableLLMFailure failure `shouldBe` True
        _ -> expectationFailure ("unexpected failure: " <> show result)
  it "reports an unknown profile without opening a provider connection" $
    withFixture "openai" False $ \config -> do
      written <- newIORef BS.empty
      manager <- recordingManager (wireResponse "openai" False) written
      let runtime = httpRuntimeFromManagers manager manager manager
      result <- withCompactLogger ColorNever Nothing $ \logger ->
        runEff
          . runLog "llm-wire-test" logger LogAttention
          . runLLM runtime (\_ _ _ -> pure ()) (\_ -> pure ()) config.llm
          $ chat callContext "absent" [MsgUser "hello"] []
      case result of
        Left (LLMUnknownProfile "absent") -> pure ()
        _ -> expectationFailure ("unexpected failure: " <> show result)
      readIORef written `shouldReturn` BS.empty
  where
    steeringSpec protocol = it ("lowers steering after all tool results for " <> protocol) $
      withFixture protocol False $ \config -> do
        written <- newIORef BS.empty
        calls <- newIORef []
        manager <- recordingManager (wireResponse protocol False) written
        let runtime = httpRuntimeFromManagers manager manager manager
            toolCalls = [ToolCall "a" "echo" (object []), ToolCall "b" "echo" (object [])]
            raw =
              if protocol == "responses"
                then toJSON [object ["type" .= ("function_call" :: Text), "call_id" .= identifier, "name" .= ("echo" :: Text), "arguments" .= ("{}" :: Text)] | identifier <- ["a", "b"] :: [Text]]
                else
                  object
                    [ "role" .= ("assistant" :: Text),
                      "tool_calls"
                        .= [object ["id" .= identifier, "type" .= ("function" :: Text), "function" .= object ["name" .= ("echo" :: Text), "arguments" .= ("{}" :: Text)]] | identifier <- ["a", "b"] :: [Text]]
                    ]
            messages = [MsgSystem "rules", MsgUser "initial", MsgAssistantToolCalls raw toolCalls, MsgTool "a" "A", MsgTool "b" "B", MsgUser "steering"]
        _ <- withCompactLogger ColorNever Nothing $ \logger ->
          runEff
            . runLog "steering-wire" logger LogAttention
            . runLLM runtime (\_ _ _ -> pure ()) (\record -> modifyIORef' calls (<> [record])) config.llm
            $ chat callContext (defaultModelName config.llm) messages []
        records <- readIORef calls
        body <- case records of [record] -> pure record.crRequest; _ -> fail "missing request"
        let field name (Object fields) = KM.lookup name fields
            field _ _ = Nothing
        items <- case field (if protocol == "responses" then "input" else "messages") body of
          Just (Array values) -> pure (V.toList values)
          _ -> fail "missing wire messages"
        field "role" (last items) `shouldBe` Just (String "user")
        case field "content" (last items) of
          Just (String bodyText) -> bodyText `shouldBe` "steering"
          Just (Array blocks) -> map (field "text") (V.toList blocks) `shouldBe` [Just (String "steering")]
          _ -> fail "missing steering text"
        case (protocol, drop 1 (reverse items)) of
          ("openai", second : first : _) -> do
            map (field "tool_call_id") [first, second] `shouldBe` map (Just . String) ["a", "b"]
            map (field "role") [first, second] `shouldBe` replicate 2 (Just (String "tool"))
          ("responses", second : first : _) -> do
            map (field "call_id") [first, second] `shouldBe` map (Just . String) ["a", "b"]
            map (field "type") [first, second] `shouldBe` replicate 2 (Just (String "function_call_output"))
          ("anthropic", result : _) -> case field "content" result of
            Just (Array blocks) -> do
              map (field "tool_use_id") (V.toList blocks) `shouldBe` map (Just . String) ["a", "b"]
              map (field "type") (V.toList blocks) `shouldBe` replicate 2 (Just (String "tool_result"))
            _ -> fail "missing tool results"
          _ -> fail "missing preceding tool results"
    protocolSpec protocol = mapM_ (oneMode protocol) [False, True]
    oneMode protocol streaming = it ("records the actual " <> protocol <> " request with stream=" <> show streaming) $
      withFixture protocol streaming $ \config -> do
        written <- newIORef BS.empty
        calls <- newIORef []
        manager <- recordingManager (wireResponse protocol streaming) written
        let runtime = httpRuntimeFromManagers manager manager manager
        result <- withCompactLogger ColorNever Nothing $ \logger ->
          runEff
            . runLog "llm-wire-test" logger LogAttention
            . runLLM runtime (\_ _ _ -> pure ()) (\record -> modifyIORef' calls (<> [record])) config.llm
            $ if streaming
              then chatStreaming callContext (defaultModelName config.llm) [MsgUser "hello"] [] (\_ -> pure ())
              else chat callContext (defaultModelName config.llm) [MsgUser "hello"] []
        result `shouldSatisfy` completed
        bytes <- readIORef written
        let (_, bodyWithSeparator) = BS.breakSubstring "\r\n\r\n" bytes
        BS.null bodyWithSeparator `shouldBe` False
        body <- either (fail . ("invalid request JSON: " <>)) pure (eitherDecodeStrict' (BS.drop 4 bodyWithSeparator))
        records <- readIORef calls
        case records of
          [record] -> do
            record.crRequest `shouldBe` body
            record.crStreamed `shouldBe` streaming
            case body of
              Object fields -> KM.lookup "stream" fields `shouldBe` Just (Bool streaming)
              _ -> expectationFailure "request body is not an object"
          _ -> expectationFailure "expected one call record"
    completed (Right (ContentResp "ok")) = True
    completed _ = False

callContext :: ChatCtx
callContext = ChatCtx "turn" Nothing Nothing (Just 5) (Just []) Nothing Nothing

withFixture :: String -> Bool -> (AppConfig -> IO a) -> IO a
withFixture protocol streaming action = withSystemTempFile "max-llm-wire.yaml" $ \path handle -> do
  hPutStr handle "{}\n"
  hClose handle
  withArgs ["--config-file", path, "--llm-api-key", "fixture-key", "--llm-model", "fixture-model", "--llm-base-url", "http://provider.test", "--llm-protocol", protocol, "--llm-stream", show streaming] $
    loadConfig >>= action

recordingManager :: ByteString -> IORef ByteString -> IO Manager
recordingManager response written =
  newManager
    defaultManagerSettings
      { managerRawConnection = pure $ \_ _ _ -> do
          remaining <- newIORef response
          makeConnection (atomicModifyIORef' remaining (BS.empty,)) (\bytes -> modifyIORef' written (<> bytes)) (pure ()),
        managerRetryableException = const False
      }

wireResponse :: String -> Bool -> ByteString
wireResponse protocol streaming =
  let body = if streaming then frames protocol else buffered protocol
      mime = if streaming then "text/event-stream" else "application/json"
   in "HTTP/1.1 200 OK\r\nContent-Type: " <> mime <> "\r\nContent-Length: " <> B8.pack (show (BS.length body)) <> "\r\nConnection: close\r\n\r\n" <> body
  where
    buffered "openai" = "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"ok\"}}],\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":1}}"
    buffered "anthropic" = "{\"content\":[{\"type\":\"text\",\"text\":\"ok\"}]}"
    buffered _ = "{\"output\":[{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\"}]}]}"
    frames "openai" = "data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\ndata: [DONE]\n\n"
    frames "anthropic" = "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"ok\"}}\n\ndata: {\"type\":\"message_stop\"}\n\n"
    frames _ = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"ok\",\"output_index\":0,\"content_index\":0}\n\ndata: {\"type\":\"response.completed\",\"response\":{\"output\":[{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\"}]}]}}\n\n"

rawResponse :: Int -> ByteString -> ByteString
rawResponse status body = "HTTP/1.1 " <> B8.pack (show status) <> " Fixture\r\nContent-Type: application/json\r\nContent-Length: " <> B8.pack (show (BS.length body)) <> "\r\nConnection: close\r\n\r\n" <> body
