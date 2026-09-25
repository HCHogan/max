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
    VisionLimits (..),
    defaultContextLimits,
    contextLimitsForWindow,
    contextInputBudget,
    contextWorkingBudget,
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
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Max.LLM.Types (TokenPrices)

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
    stream :: !Bool,
    -- | Send 'CacheBoundary' markers to the server as prefix-cache hints.
    promptCacheBreakpoints :: !Bool,
    -- | Soft budget for the context Max assembles up front; see 'ContextLimits'.
    contextBudget :: !(Maybe Int),
    visionLimits :: !(Maybe VisionLimits),
    -- | Configured prices; absent means calls on this profile carry no cost.
    prices :: !(Maybe TokenPrices)
  }
  deriving stock (Eq)

-- | A provider's vision envelope. A request that exceeds any bound is rejected
-- whole, so Max prepares and budgets media to fit before sending them.
data VisionLimits = VisionLimits
  { -- | Vision tokens of all images and videos in one request.
    requestTokens :: !Int,
    -- | Vision tokens of one image or video.
    itemTokens :: !Int,
    -- | Longest video segment the server accepts.
    videoMaxSeconds :: !Int,
    -- | Most frames the server samples from one video.
    videoMaxFrames :: !Int,
    -- | Pixel volume (frames × height × width) the server's video processor
    -- keeps before downscaling; 2048 pixels make one token.
    videoMaxPixels :: !Int
  }
  deriving stock (Show, Eq)

-- | Resolved prompt-side limits. Output has already been subtracted from the
-- configured combined window to obtain @maxInputTokens@. Consumers must not
-- subtract it again; media and tool reserves live inside this input ceiling.
data ContextLimits = ContextLimits
  { maxInputTokens :: !Int,
    reservedOutputTokens :: !Int,
    attachmentReserve :: !Int,
    toolRoundReserve :: !Int,
    -- | Optional soft budget for the context assembled up front (raw tail,
    -- summaries, memories, read pages). It trades prefill time and long-context
    -- quality against recall; the hard ceilings above still bound a turn.
    workingBudget :: !(Maybe Int),
    -- | Declared provider vision envelope; absent means media are sent as-is.
    visionLimits :: !(Maybe VisionLimits)
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
      toolRoundReserve = 16384,
      workingBudget = Nothing,
      visionLimits = Nothing
    }

-- | Resolve a combined input/output window once, before any prompt planning.
-- One eighth each is the default output allowance, tool-round headroom and
-- (for multimodal profiles) attachment allowance. An explicit provider output
-- cap changes the derived hard input ceiling, not the total window.
contextLimitsForWindow :: Int -> Maybe Int -> Bool -> Either Text ContextLimits
contextLimitsForWindow window outputOverride multimodal
  | window < 2 = Left "context_window must leave room for input and output"
  | output <= 0 = Left "max_tokens must be positive"
  | output >= window = Left "max_tokens must be smaller than context_window"
  | otherwise = Right (ContextLimits input output media reserve Nothing Nothing)
  where
    reserve = window `div` 8
    output = fromMaybe (max 1 reserve) outputOverride
    input = window - output
    media = if multimodal then reserve else 0

-- | Text-message budget after reserving space for future tool rounds and,
-- only when present, multimodal attachments.
contextInputBudget :: ContextLimits -> Bool -> Int
contextInputBudget limits hasAttachments =
  max 0 $
    limits.maxInputTokens
      - limits.toolRoundReserve
      - if hasAttachments then limits.attachmentReserve else 0

-- | The budget up-front context capacities derive from: the soft working
-- budget when configured, never more than the hard input budget.
contextWorkingBudget :: ContextLimits -> Bool -> Int
contextWorkingBudget limits hasAttachments = maybe hard (min hard) limits.workingBudget
  where
    hard = contextInputBudget limits hasAttachments

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
                  toolRoundReserve = profile.toolRoundReserve,
                  workingBudget = profile.contextBudget,
                  visionLimits = profile.visionLimits
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
