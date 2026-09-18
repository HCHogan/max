-- | Apply session and per-call model overrides.
module Max.LLM.Configuration (configureCallProfile) where

import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Max.LLM.CallContext (ChatCtx (..))
import Max.ModelCatalog.Internal (LLMProfile (..), ModelCatalog, lookupCompletionProfile)

configureCallProfile :: ModelCatalog -> ChatCtx -> Text -> Maybe LLMProfile
configureCallProfile catalog ctx name = do
  original <- lookupCompletionProfile name catalog
  let configured = maybe original (\effort -> original {effort = Just effort}) ctx.ccEffort
  pure configured {timeoutSeconds = max 1 (fromMaybe configured.timeoutSeconds ctx.ccTimeoutSeconds)}
