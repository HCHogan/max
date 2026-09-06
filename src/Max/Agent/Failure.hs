-- | Reasons a model/tool loop stops without completing normally.
module Max.Agent.Failure (AgentFailure (..), renderAgentFailure, retryableAgentFailure) where

import Data.Aeson (ToJSON (..), object, (.=))
import Data.Text (Text)
import Max.Http.Failure (ResponseFailure, renderResponseFailure)
import Max.LLM.Failure (LLMFailure, renderLLMFailure, retryableLLMFailure)

data AgentFailure
  = AgentModelFailure !LLMFailure
  | AgentStreamInterrupted !ResponseFailure
  | AgentRoundLimit
  deriving stock (Eq, Show)

renderAgentFailure :: AgentFailure -> Text
renderAgentFailure = \case
  AgentModelFailure failure -> renderLLMFailure failure
  AgentStreamInterrupted failure -> "LLM stream interrupted: " <> renderResponseFailure failure
  AgentRoundLimit -> "max-turns"

retryableAgentFailure :: AgentFailure -> Bool
retryableAgentFailure = \case
  AgentModelFailure failure -> retryableLLMFailure failure
  -- Some text or tool-call bytes already arrived. Retrying a durable task
  -- after a partial response must not replay its externally visible prefix.
  AgentStreamInterrupted _ -> False
  AgentRoundLimit -> False

instance ToJSON AgentFailure where
  toJSON failure = object ["kind" .= kind, "detail" .= renderAgentFailure failure]
    where
      kind :: Text
      kind = case failure of
        AgentModelFailure _ -> "model"
        AgentStreamInterrupted _ -> "stream_interrupted"
        AgentRoundLimit -> "round_limit"
