-- | Call/usage observations. Failed accounting is diagnostic and never
-- reclassifies a completed provider call; asynchronous cancellation propagates.
module Max.LLM.Observability (recordChatResult, logChatRequest) where

import Data.Aeson (Value)
import Data.Aeson.Types (Pair)
import Data.Foldable (for_)
import Data.Text (Text)
import Data.Text qualified as T
import Effectful
import Effectful.Exception (SomeException)
import Effectful.Log
import Max.Http.Failure (renderResponseFailure)
import Max.LLM.CallContext
import Max.LLM.Failure (LLMFailure, renderLLMFailure)
import Max.LLM.Protocol (requestBodyFor)
import Max.LLM.Types
import Max.ModelCatalog.Internal (LLMProfile (..))
import Max.Tool.Types (ToolSpec)
import Max.Util (trySync)

logChatRequest :: (Log :> es) => Text -> LLMProfile -> Bool -> Int -> Int -> Int -> Eff es ()
logChatRequest name cfg streaming messageCount toolCount retries =
  logInfo "llm: chat request" $ object ["msg_count" .= messageCount, "tool_count" .= toolCount, "profile" .= name, "model" .= cfg.model, "stream" .= streaming, "timeout_seconds" .= cfg.timeoutSeconds, "transport_retries" .= retries]

recordChatResult :: (Log :> es, IOE :> es) => UsageWriter -> CallWriter -> ChatCtx -> Text -> LLMProfile -> Bool -> [ChatMessage] -> [ToolSpec] -> Int -> Either LLMFailure (ChatResponse, Maybe TokenUsage) -> Eff es ()
recordChatResult usageWriter callWriter ctx name cfg streaming msgs tools durationMs r = do
  case r of
    Left err ->
      logAttention "llm: error" $
        object ["error" .= err, "profile" .= name]
    Right (ContentResp text, mUsage) ->
      logInfo "llm: got content" $
        object $
          ["len" .= T.length text, "profile" .= name] <> usageFields mUsage
    Right (InterruptedResp text reason, _) ->
      logAttention "llm: interrupted content" $
        object ["len" .= T.length text, "profile" .= name, "error" .= reason]
    Right (ToolCallsResp _ narration tcs, mUsage) ->
      logInfo "llm: got tool_calls" $
        object $
          [ "count" .= length tcs,
            "narration_len" .= T.length narration,
            "names" .= map (.callName) tcs,
            "profile" .= name
          ]
            <> usageFields mUsage
  -- Book the spend.  Guarded: a lost accounting row must never fail
  -- the call it describes.
  for_ [u | Right (_, Just u) <- [r]] $ \u ->
    trySync (liftIO (usageWriter ctx name u)) >>= \case
      Left e ->
        logAttention "llm: usage write failed" $
          object ["error" .= T.pack (show (e :: SomeException))]
      Right () -> pure ()
  -- Record the whole exchange, success or not.  Same guard, same
  -- reason — and note this runs on the failure branch too, which is
  -- the branch whose request body you actually want to read.
  trySync
    ( liftIO . callWriter $
        CallRecord
          { crCtx = ctx,
            crProfile = name,
            crModel = cfg.model,
            crStreamed = streaming,
            crDurationMs = durationMs,
            crRequest = requestBodyFor cfg msgs tools streaming,
            crResponse = either (const Nothing) (Just . responseJson . fst) r,
            crError = case r of
              Left err -> Just (renderLLMFailure err)
              Right (InterruptedResp _ reason, _) -> Just (renderResponseFailure reason)
              Right _ -> Nothing,
            crUsage = either (const Nothing) snd r
          }
    )
    >>= \case
      Left e ->
        logAttention "llm: call log write failed" $
          object ["error" .= T.pack (show (e :: SomeException))]
      Right () -> pure ()

responseJson :: ChatResponse -> Value
responseJson = \case
  ContentResp t -> object ["content" .= t]
  InterruptedResp t reason -> object ["content" .= t, "interrupted" .= True, "error" .= reason]
  ToolCallsResp raw narration tcs ->
    object
      [ "raw" .= raw,
        "narration" .= narration,
        "tool_calls"
          .= [ object ["name" .= tc.callName, "arguments" .= tc.callArguments]
             | tc <- tcs
             ]
      ]

-- | Usage as extra log fields; absent wholesale when the provider
-- reported none.
usageFields :: Maybe TokenUsage -> [Pair]
usageFields Nothing = []
usageFields (Just u) =
  [ "prompt_tokens" .= u.usagePrompt,
    "completion_tokens" .= u.usageCompletion
  ]
    <> maybe [] (\c -> ["cached_prompt_tokens" .= c]) u.usageCachedPrompt
