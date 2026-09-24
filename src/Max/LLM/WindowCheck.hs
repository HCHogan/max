-- | Advisory startup check: compare each profile's configured combined window
-- with the context length its server reports. The configuration stays the
-- source of truth; a server that reports nothing or cannot be reached is
-- skipped, and a larger configured window only produces a warning.
module Max.LLM.WindowCheck (checkContextWindows, reportedContextWindow) where

import Data.Aeson (Value (..), eitherDecodeStrict', object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Foldable (for_, toList)
import Data.List (nub)
import Data.Maybe (fromMaybe, listToMaybe, mapMaybe)
import Data.Scientific (toBoundedInteger)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Effectful
import Effectful.Log (Log, logAttention, logInfo)
import Max.HttpRuntime
import Max.ModelCatalog (LLMProfile (..), ModelCatalog, Protocol (..), modelProfileNames)
import Max.ModelCatalog.Internal (lookupCompletionProfile)
import Network.HTTP.Client qualified as HTTP
import System.Timeout (timeout)

checkContextWindows :: (Log :> es, IOE :> es) => HttpRuntime -> ModelCatalog -> Eff es ()
checkContextWindows runtime catalog =
  -- One request per server, however many profiles share it.
  for_ (nub [(p.baseUrl, p.apiKey) | (_, p) <- profiles]) $ \server@(baseUrl, _) -> do
    listing <- liftIO (fetchModels runtime server)
    case listing of
      Left reason -> logInfo "context window check skipped" (object ["base_url" .= baseUrl, "reason" .= reason])
      Right models ->
        for_ [(name, p) | (name, p) <- profiles, (p.baseUrl, p.apiKey) == server] $ \(name, p) -> do
          let configured = p.maxInputTokens + p.maxTokens
          case reportedContextWindow p.model models of
            Just reported
              | configured > reported ->
                  logAttention
                    "llm profile context_window exceeds the server's reported context"
                    (object ["profile" .= name, "model" .= p.model, "configured" .= configured, "reported" .= reported])
            _ -> pure ()
  where
    -- Anthropic's model listing carries no context length.
    profiles = [(name, p) | name <- modelProfileNames catalog, Just p <- [lookupCompletionProfile name catalog], p.protocol /= ProtocolAnthropic]

fetchModels :: HttpRuntime -> (Text, Text) -> IO (Either Text Value)
fetchModels runtime (baseUrl, apiKey) = do
  result <- timeout 10_000_000 $
    parseRequestEither (T.unpack (T.dropWhileEnd (== '/') baseUrl <> "/models")) >>= \case
      Left failure -> pure (Left (T.pack (show failure)))
      Right request ->
        either (Left . T.pack . show) (decodeBody . (.body))
          <$> runBuffered
            runtime
            StandardPool
            4_000_000
            512
            request
              { HTTP.requestHeaders = [("Authorization", TE.encodeUtf8 ("Bearer " <> apiKey)) | not (T.null apiKey)],
                HTTP.responseTimeout = HTTP.responseTimeoutMicro 10_000_000
              }
  pure (fromMaybe (Left "timed out") result)
  where
    decodeBody = either (Left . T.pack) Right . eitherDecodeStrict'

-- | The context length a models listing reports for one model id, under the
-- field names llama-swap/NInfer, vLLM and OpenRouter-style gateways use.
reportedContextWindow :: Text -> Value -> Maybe Int
reportedContextWindow model = \case
  Object listing | Just (Array entries) <- KM.lookup "data" listing ->
    listToMaybe [window | Object entry <- toList entries, KM.lookup "id" entry == Just (String model), Just window <- [firstWindow entry]]
  _ -> Nothing
  where
    firstWindow entry = listToMaybe (mapMaybe (\key -> KM.lookup (Key.fromText key) entry >>= positive) ["context_length", "max_context_length", "max_model_len", "context_window"])
    positive = \case
      Number n | Just value <- toBoundedInteger n, value > 0 -> Just value
      _ -> Nothing
