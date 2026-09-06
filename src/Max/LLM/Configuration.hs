-- | Resolve the leased model catalog and apply per-call profile overrides.
module Max.LLM.Configuration (resolveCallCatalog, configureCallProfile) where

import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Max.LLM.CallContext (ChatCtx (..))
import Max.LLM.Failure (LLMFailure (..))
import Max.ModelCatalog.Internal (LLMProfile (..), ModelCatalog, lookupCompletionProfile)
import Max.RuntimeConfig (RuntimeConfigStore, RuntimeSnapshot (..), RuntimeValues (..), currentRuntimeSnapshot, lookupRuntimeSnapshot)

resolveCallCatalog :: RuntimeConfigStore -> ChatCtx -> IO (Either LLMFailure ModelCatalog)
resolveCallCatalog store ctx = do
  snapshot <- case ctx.ccConfigGeneration of
    Nothing -> Right <$> currentRuntimeSnapshot store
    Just generation ->
      lookupRuntimeSnapshot store generation >>= \case
        Just snapshot -> pure (Right snapshot)
        Nothing -> pure (Left LLMReleasedConfiguration)
  pure ((.rvModelCatalog) . (.rsValues) <$> snapshot)

configureCallProfile :: ModelCatalog -> ChatCtx -> Text -> Maybe LLMProfile
configureCallProfile catalog ctx name = do
  original <- lookupCompletionProfile name catalog
  let configured = maybe original (\effort -> original {effort = Just effort}) ctx.ccEffort
  pure configured {timeoutSeconds = max 1 (fromMaybe configured.timeoutSeconds ctx.ccTimeoutSeconds)}
