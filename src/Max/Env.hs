-- | Process-lifetime resources and configuration.
module Max.Env
  ( BotEnv (..),
  )
where

import Control.Concurrent.STM (TVar)
import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Text (Text)
import Data.Time (TimeZone, UTCTime)
import Max.Browser.Registry (BrowserRegistry)
import Max.CliProxy (CliProxyConfig)
import Max.Conversation (Conversations)
import Max.Embedding.Maintenance (EmbeddingLock)
import Max.EpisodeScheduler (EpisodeScheduler)
import Max.FetchQueue (FetchSignal)
import Max.Intent.Types (IntentConfig)
import Max.Jobs (Jobs)
import Max.Platform.Delivery.Queue (DeliveryQueue)
import Max.Platform.Ingress (Ingress)
import Max.Sandbox.Registry (SandboxRegistry)
import Max.Search.Runtime (SearchRuntime)
import Max.Session (SessionRegistry)
import Max.Shutdown (ShutdownState)
import Max.Skills (SkillRegistry)
import Max.Tasks (TaskRegistry)

-- AppConfig is read once in Main. These immutable projections are the serving
-- configuration; session overrides stay in SessionRegistry.
data BotEnv = BotEnv
  { bePersona :: !Text,
    beForceRawContext :: !Bool,
    beDebugDefault :: !Bool,
    beStickerDefault :: !Bool,
    beDefaultModel :: !Text,
    beTimeZone :: !TimeZone,
    beTurnSilenceSeconds :: !Int,
    beOwners :: ![Int64],
    beWebhookBaseUrl :: !(Maybe Text),
    beSearch :: !(Maybe SearchRuntime),
    beCliProxy :: !(Maybe CliProxyConfig),
    beBrowserProxy :: !(Maybe Text),
    -- | Historian profile; the configuration retains its memory-extract key.
    beMemoryExtract :: !(Maybe Text),
    beIntent :: !(Maybe IntentConfig),
    -- | Product gating only; calls use the Embedding effect.
    beEmbeddingEnabled :: !Bool,
    -- Process-owned resources, allocated and closed by Main/Worker.
    beStartedAt :: !UTCTime,
    beSessions :: !SessionRegistry,
    beSkills :: !SkillRegistry,
    beTasks :: !TaskRegistry,
    beConversations :: !Conversations,
    beJobs :: !Jobs,
    beIngress :: !Ingress,
    beFetch :: !FetchSignal,
    beDeliveries :: !DeliveryQueue,
    beShutdown :: !ShutdownState,
    -- | Private-chat !use targets are forgotten on restart.
    beAdminTarget :: !(TVar (Map Int64 Int64)),
    beSandboxes :: !SandboxRegistry,
    beBrowsers :: !BrowserRegistry,
    -- | Present exactly when Historian is enabled.
    beEpisodeScheduler :: !(Maybe EpisodeScheduler),
    beEmbeddingLock :: !EmbeddingLock
  }
