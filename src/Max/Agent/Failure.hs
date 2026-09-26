-- | Reasons a model/tool loop stops without completing normally.
module Max.Agent.Failure (AgentFailure (..), renderAgentFailure) where

import Data.Aeson (ToJSON (..), object, (.=))
import Data.Text (Text)
import Max.Http.Failure (ResponseFailure, renderResponseFailure)
import Max.LLM.Failure (LLMFailure, renderLLMFailure)

data AgentFailure
  = AgentModelFailure !LLMFailure
  | AgentStreamInterrupted !ResponseFailure
  | AgentContextBudget !Text
  | AgentRoundLimit
  | AgentBudgetExhausted
  deriving stock (Eq, Show)

renderAgentFailure :: AgentFailure -> Text
renderAgentFailure = \case
  AgentModelFailure failure -> renderLLMFailure failure
  AgentStreamInterrupted failure -> "LLM stream interrupted: " <> renderResponseFailure failure
  AgentContextBudget detail -> "context budget: " <> detail
  AgentRoundLimit -> "max-turns"
  AgentBudgetExhausted -> "agent tree budget exhausted"

instance ToJSON AgentFailure where
  toJSON failure = object ["kind" .= kind, "detail" .= renderAgentFailure failure]
    where
      kind :: Text
      kind = case failure of
        AgentModelFailure _ -> "model"
        AgentStreamInterrupted _ -> "stream_interrupted"
        AgentContextBudget _ -> "context_budget"
        AgentRoundLimit -> "round_limit"
        AgentBudgetExhausted -> "budget_exhausted"
