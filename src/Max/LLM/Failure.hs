-- | Model call failures before a completed response. A partial response is
-- represented separately in ChatResponse and cannot be transparently retried.
module Max.LLM.Failure (LLMFailure (..), renderLLMFailure, retryableLLMFailure) where

import Data.Aeson (ToJSON (..), object, (.=))
import Data.Text (Text)
import Max.Http.Failure

data LLMFailure
  = LLMResponseFailure !ResponseFailure
  | LLMUnknownProfile !Text
  | LLMReleasedConfiguration
  deriving stock (Eq, Show)

renderLLMFailure :: LLMFailure -> Text
renderLLMFailure = \case
  LLMResponseFailure failure -> renderResponseFailure failure
  LLMUnknownProfile name -> "unknown llm profile: " <> name
  LLMReleasedConfiguration -> "LLM call referenced a released configuration generation"

retryableLLMFailure :: LLMFailure -> Bool
retryableLLMFailure = \case
  LLMResponseFailure failure -> retryableResponseFailure failure
  LLMUnknownProfile _ -> False
  LLMReleasedConfiguration -> False

instance ToJSON LLMFailure where
  toJSON failure = object ["kind" .= kind, "detail" .= renderLLMFailure failure]
    where
      kind :: Text
      kind = case failure of
        LLMResponseFailure _ -> "response"
        LLMUnknownProfile _ -> "unknown_profile"
        LLMReleasedConfiguration -> "released_configuration"
