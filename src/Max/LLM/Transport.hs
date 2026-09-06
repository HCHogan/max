-- | Model HTTP execution and stream lifetime. Protocol encoding is shared by
-- buffered/streamed sends and observability; provider retries stay in Http.
module Max.LLM.Transport (callChat, callChatStream, interruptionMarker) where

import Data.Aeson (encode)
import Data.Bifunctor (first)
import Data.ByteString.Lazy qualified as LBS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Effectful
import Effectful.Log
import Max.Http.Json (postAndParseRetrying, replyRetryDelaysSecs)
import Max.Http.Stream (StreamOutcome (..), streamPost)
import Max.HttpRuntime (HttpRuntime)
import Max.LLM.Failure (LLMFailure (..))
import Max.LLM.Protocol
import Max.LLM.Stream (StreamAcc (..), accToolCalls, stepAnthropic, stepOpenAI, stepResponses)
import Max.LLM.Types
import Max.ModelCatalog.Internal (LLMProfile (..), Protocol (..))
import Max.Tool.Types (ToolSpec)
import Network.HTTP.Types.Header (RequestHeaders)

callChat :: (Log :> es, IOE :> es) => HttpRuntime -> [Int] -> LLMProfile -> [ChatMessage] -> [ToolSpec] -> Eff es (Either LLMFailure (ChatResponse, Maybe TokenUsage))
callChat runtime retries cfg messages tools =
  first LLMResponseFailure <$> postAndParseRetrying runtime retries cfg.timeoutSeconds headers url body parser
  where
    (url, headers) = completionTarget cfg
    body = LBS.toStrict (encode (requestBodyFor cfg messages tools False))
    parser = case cfg.protocol of
      ProtocolOpenAI -> parseResponseOpenAI
      ProtocolAnthropic -> parseResponseAnthropic
      ProtocolResponses -> parseResponseResponses

callChatStream :: (Log :> es, IOE :> es) => HttpRuntime -> LLMProfile -> [ChatMessage] -> [ToolSpec] -> (Text -> Eff es ()) -> Eff es (Either LLMFailure (ChatResponse, Maybe TokenUsage))
callChatStream runtime cfg messages tools sink = do
  outcome <- streamPost runtime replyRetryDelaysSecs cfg.timeoutSeconds (("Accept", "text/event-stream") : headers) url body step $ \acc ->
    sink (stripLeadingThink acc.saText)
  case outcome of
    StreamFailed failure -> pure (Left (LLMResponseFailure failure))
    StreamComplete acc -> pure (Right (rebuild acc, accUsage acc))
    StreamTruncated acc reason -> do
      -- A partial tool argument may even be valid JSON while missing fields.
      -- Never execute or replay it; preserve only the text already shown.
      logAttention "llm: stream truncated" $ object ["reason" .= reason, "len" .= T.length acc.saText, "partial_calls" .= length (accToolCalls acc)]
      pure (Right (InterruptedResp (stripLeadingThink acc.saText <> interruptionMarker) reason, accUsage acc))
  where
    (url, headers) = completionTarget cfg
    body = LBS.toStrict (encode (requestBodyFor cfg messages tools True))
    (step, rebuild) = case cfg.protocol of
      ProtocolOpenAI -> (stepOpenAI, rebuildOpenAI)
      ProtocolAnthropic -> (stepAnthropic, rebuildAnthropic)
      ProtocolResponses -> (stepResponses, rebuildResponses)
    accUsage acc = case (acc.saPromptTokens, acc.saCompletionTokens) of
      (Just prompt, Just completion) -> Just (TokenUsage prompt completion acc.saCachedTokens)
      _ -> Nothing

completionTarget :: LLMProfile -> (String, RequestHeaders)
completionTarget cfg = case cfg.protocol of
  ProtocolAnthropic -> (T.unpack (cfg.baseUrl <> "/v1/messages"), [("x-api-key", TE.encodeUtf8 cfg.apiKey), ("anthropic-version", "2023-06-01"), ("Content-Type", "application/json")])
  protocol -> (T.unpack (cfg.baseUrl <> path protocol), [("Authorization", "Bearer " <> TE.encodeUtf8 cfg.apiKey), ("Content-Type", "application/json")])
  where
    path ProtocolResponses = "/responses"
    path _ = "/chat/completions"

interruptionMarker :: Text
interruptionMarker = "\n\n⚠ 断了，上面这条没写完"
