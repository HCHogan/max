-- | Apply session and per-call model overrides.
module Max.LLM.Configuration (configureCallProfile, completionAllowance) where

import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Max.LLM.CallContext (ChatCtx (..))
import Max.ModelCatalog.Internal (LLMProfile (..), ModelCatalog, lookupCompletionProfile)

configureCallProfile :: ModelCatalog -> ChatCtx -> Text -> Maybe LLMProfile
configureCallProfile catalog ctx name = do
  original <- lookupCompletionProfile name catalog
  let configured = maybe original (\effort -> original {effort = Just effort}) ctx.ccEffort
  pure
    configured
      { timeoutSeconds = max 1 (fromMaybe configured.timeoutSeconds ctx.ccTimeoutSeconds),
        maxTokens = completionAllowance configured ctx.ccPromptTokens
      }

-- | The completion limit sent with one request. A fixed limit is the planning
-- reserve. An adaptive one gives the completion what the declared window
-- leaves after the estimated prompt, with a quarter of the estimate plus 1024
-- tokens of slack for estimation error, and never less than the reserve.
completionAllowance :: LLMProfile -> Maybe Int -> Int
completionAllowance profile = \case
  Just prompt | profile.adaptiveOutput -> max profile.maxTokens (window - prompt - prompt `div` 4 - 1024)
  _ -> profile.maxTokens
  where
    window = profile.maxInputTokens + profile.maxTokens
