-- |
-- Internal backing types for "Max.ModelCatalog" and the completion runner.
--
-- This module is deliberately hidden by Cabal: it contains endpoint
-- credentials and provider transport settings. Ordinary application code
-- must use the safe projection exported by "Max.ModelCatalog".
module Max.ModelCatalog.Internal
  ( ModelCatalog,
    ModelCatalogError (..),
    ContextLimits (..),
    defaultContextLimits,
    contextInputBudget,
    ModelCapabilities (..),
    LLMProfile (..),
    Protocol (..),
    parseProtocol,
    mkModelCatalogFromCapabilities,
    mkModelCatalogFromProfiles,
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

-- | Full completion endpoint configuration. This type must not cross the
-- internal catalog/LLM boundary because it contains credentials.
data LLMProfile = LLMProfile
  { baseUrl :: !Text,
    apiKey :: !Text,
    model :: !Text,
    maxInputTokens :: !Int,
    maxTokens :: !Int,
    attachmentReserve :: !Int,
    toolRoundReserve :: !Int,
    temperature :: !(Maybe Double),
    effort :: !(Maybe Text),
    timeoutSeconds :: !Int,
    protocol :: !Protocol,
    multimodal :: !Bool,
    historyAsTurns :: !Bool,
    stream :: !Bool
  }
  deriving stock (Eq)

-- | Prompt-side limits for one model profile.  @maxInputTokens@ is the
-- provider's hard input ceiling.  Output is tracked separately because it is
-- sent as the completion limit, while attachment and future tool-round
-- reserves consume space inside the input ceiling before history is planned.
data ContextLimits = ContextLimits
  { maxInputTokens :: !Int,
    reservedOutputTokens :: !Int,
    attachmentReserve :: !Int,
    toolRoundReserve :: !Int
  }
  deriving stock (Show, Eq)

-- | Roomy group-chat defaults for profiles that omit explicit limits.  The
-- input/output pair fits a 128K combined-window deployment, while the reserves
-- leave enough headroom for a long tool loop and the largest inline-media turn
-- Max currently admits.
defaultContextLimits :: ContextLimits
defaultContextLimits =
  ContextLimits
    { maxInputTokens = 114688,
      reservedOutputTokens = 16384,
      attachmentReserve = 16384,
      toolRoundReserve = 16384
    }

-- | Text-message budget after reserving space for future tool rounds and,
-- only when present, multimodal attachments.
contextInputBudget :: ContextLimits -> Bool -> Int
contextInputBudget limits hasAttachments =
  max 0 $
    limits.maxInputTokens
      - limits.toolRoundReserve
      - if hasAttachments then limits.attachmentReserve else 0

-- | Safe projection used by prompt construction and command/status paths.
data ModelCapabilities = ModelCapabilities
  { supportsMultimodal :: !Bool,
    usesHistoryTurns :: !Bool,
    configuredEffort :: !(Maybe Text),
    contextLimits :: !ContextLimits
  }
  deriving stock (Show, Eq)

-- | A production entry retains its completion configuration. The
-- capability-only case supports pure consumers and their tests without making
-- credentials constructible or observable through the public module.
data CatalogEntry
  = CompletionEntry !LLMProfile
  | CapabilityEntry !ModelCapabilities
  deriving stock (Eq)

-- | One immutable source of truth for public capabilities and private
-- completion configuration. Constructors stay internal so every catalog
-- establishes the default-profile invariant.
data ModelCatalog = ModelCatalog
  { catalogDefaultName :: !Text,
    catalogProfiles :: !(Map Text CatalogEntry)
  }
  deriving stock (Eq)

-- Keep 'AppConfig' printable without ever rendering endpoint credentials.
instance Show ModelCatalog where
  show catalog =
    "ModelCatalog {default = "
      <> show catalog.catalogDefaultName
      <> ", profiles = "
      <> show (Map.keys catalog.catalogProfiles)
      <> "}"

data ModelCatalogError
  = DefaultModelMissing !Text
  deriving stock (Show, Eq)

mkModelCatalogFromCapabilities :: Text -> Map Text ModelCapabilities -> Either ModelCatalogError ModelCatalog
mkModelCatalogFromCapabilities defaultName =
  mkModelCatalogEntries defaultName . Map.map CapabilityEntry

mkModelCatalogFromProfiles :: Text -> Map Text LLMProfile -> Either ModelCatalogError ModelCatalog
mkModelCatalogFromProfiles defaultName =
  mkModelCatalogEntries defaultName . Map.map CompletionEntry

mkModelCatalogEntries :: Text -> Map Text CatalogEntry -> Either ModelCatalogError ModelCatalog
mkModelCatalogEntries defaultName profiles
  | Map.member defaultName profiles = Right (ModelCatalog defaultName profiles)
  | otherwise = Left (DefaultModelMissing defaultName)

defaultModelName :: ModelCatalog -> Text
defaultModelName = (.catalogDefaultName)

-- | Deterministic (Map-key) order, suitable for command/admin presentation.
modelProfileNames :: ModelCatalog -> [Text]
modelProfileNames = Map.keys . (.catalogProfiles)

lookupModelCapabilities :: Text -> ModelCatalog -> Maybe ModelCapabilities
lookupModelCapabilities name catalog =
  capabilitiesOf <$> Map.lookup name catalog.catalogProfiles
  where
    capabilitiesOf = \case
      CapabilityEntry capabilities -> capabilities
      CompletionEntry profile ->
        ModelCapabilities
          { supportsMultimodal = profile.multimodal,
            usesHistoryTurns = profile.historyAsTurns,
            configuredEffort = profile.effort,
            contextLimits =
              ContextLimits
                { maxInputTokens = profile.maxInputTokens,
                  reservedOutputTokens = profile.maxTokens,
                  attachmentReserve = profile.attachmentReserve,
                  toolRoundReserve = profile.toolRoundReserve
                }
          }

-- | Private completion settings for the LLM interpreter. Production catalogs
-- derive their safe capability view from this same entry rather than
-- maintaining a second registry that could drift.
lookupCompletionProfile :: Text -> ModelCatalog -> Maybe LLMProfile
lookupCompletionProfile name catalog =
  Map.lookup name catalog.catalogProfiles >>= \case
    CompletionEntry profile -> Just profile
    CapabilityEntry _ -> Nothing
