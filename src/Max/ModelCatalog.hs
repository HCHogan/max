-- |
-- Immutable model-profile catalog, materialized once from configuration.
--
-- Ordinary consumers should use 'ModelCapabilities': it contains the facts
-- needed to choose prompt/tool shape without exposing endpoint credentials.
-- The completion interpreter uses 'lookupCompletionProfile' to resolve the
-- private wire configuration from the same catalog, so the two views cannot
-- drift.
module Max.ModelCatalog
  ( ModelCatalog,
    ModelCatalogError (..),
    ModelCapabilities (..),
    LLMProfile (..),
    Protocol (..),
    parseProtocol,
    mkModelCatalog,
    defaultModelName,
    modelProfileNames,
    lookupModelCapabilities,
    lookupCompletionProfile,
  )
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T

-- | Which wire format an endpoint speaks.
data Protocol
  = -- | OpenAI Chat Completions (including compatible providers).
    ProtocolOpenAI
  | -- | Native Anthropic Messages API.
    ProtocolAnthropic
  | -- | OpenAI Responses API.
    ProtocolResponses
  deriving stock (Show, Eq, Enum, Bounded)

-- | Parse a protocol name from configuration.
parseProtocol :: Text -> Maybe Protocol
parseProtocol t = case T.toLower (T.strip t) of
  "openai" -> Just ProtocolOpenAI
  "anthropic" -> Just ProtocolAnthropic
  "responses" -> Just ProtocolResponses
  "openai-responses" -> Just ProtocolResponses
  _ -> Nothing

-- | Full completion endpoint configuration.  It deliberately remains
-- separate from 'ModelCapabilities': prompt and command consumers should not
-- need credentials, URLs, transport policy, or provider wire details.
data LLMProfile = LLMProfile
  { baseUrl :: !Text,
    apiKey :: !Text,
    model :: !Text,
    maxTokens :: !Int,
    temperature :: !(Maybe Double),
    effort :: !(Maybe Text),
    timeoutSeconds :: !Int,
    protocol :: !Protocol,
    multimodal :: !Bool,
    historyAsTurns :: !Bool,
    stream :: !Bool
  }
  deriving stock (Show, Eq)

-- | Safe projection used by prompt construction and command/status paths.
data ModelCapabilities = ModelCapabilities
  { supportsMultimodal :: !Bool,
    usesHistoryTurns :: !Bool,
    configuredEffort :: !(Maybe Text)
  }
  deriving stock (Show, Eq)

-- | One immutable source of truth for public capabilities and private
-- completion configuration.  Keep the constructor hidden so the default
-- profile invariant is established once by 'mkModelCatalog'.
data ModelCatalog = ModelCatalog
  { catalogDefaultName :: !Text,
    catalogProfiles :: !(Map Text LLMProfile)
  }
  deriving stock (Show, Eq)

data ModelCatalogError
  = DefaultModelMissing !Text
  deriving stock (Show, Eq)

-- | Construct a catalog only when its configured default exists.
mkModelCatalog :: Text -> Map Text LLMProfile -> Either ModelCatalogError ModelCatalog
mkModelCatalog defaultName profiles
  | Map.member defaultName profiles = Right (ModelCatalog defaultName profiles)
  | otherwise = Left (DefaultModelMissing defaultName)

defaultModelName :: ModelCatalog -> Text
defaultModelName = (.catalogDefaultName)

-- | Deterministic (Map-key) order, suitable for command/admin presentation.
modelProfileNames :: ModelCatalog -> [Text]
modelProfileNames = Map.keys . (.catalogProfiles)

lookupModelCapabilities :: Text -> ModelCatalog -> Maybe ModelCapabilities
lookupModelCapabilities name catalog = do
  profile <- lookupCompletionProfile name catalog
  pure
    ModelCapabilities
      { supportsMultimodal = profile.multimodal,
        usesHistoryTurns = profile.historyAsTurns,
        configuredEffort = profile.effort
      }

-- | Private completion settings for the LLM interpreter.  Keeping this query
-- on the catalog (rather than copying its Map into the interpreter) preserves
-- a single source of truth.
lookupCompletionProfile :: Text -> ModelCatalog -> Maybe LLMProfile
lookupCompletionProfile name = Map.lookup name . (.catalogProfiles)
