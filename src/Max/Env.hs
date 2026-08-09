-- |
-- Process-wide dispatch environment, carried through the stack as
-- @Reader BotEnv@ (see "Effectful.Reader.Dynamic").  Collapses the
-- config values and registry handles that every dispatch needs —
-- previously threaded as nine positional parameters through
-- 'Max.Handler' and "Max.Command.Dispatcher" — into one record built
-- once in @app/Main.hs@.
--
-- Nothing here is per-dispatch state: these are process-lifetime
-- handles and config defaults.  Per-dispatch data (group, sender,
-- trigger message) keeps travelling as explicit arguments /
-- 'Max.ToolContext.ToolContext'.
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
import Max.EpisodeScheduler (EpisodeScheduler)
import Max.Intent (IntentConfig)
import Max.Monitor (MonitorScheduler)
import Max.Sandbox.Registry (SandboxRegistry)
import Max.Session (SessionRegistry)
import Max.Shutdown (ShutdownState)
import Max.Skills (SkillRegistry)
import Max.Tasks (TaskRegistry)
import Max.Tools.Search (SearchConfig)

data BotEnv = BotEnv
  { -- | Persona used when a session hasn't overridden it ('AppConfig.persona').
    bePersona :: !Text,
    -- | Global emergency reader: raw immutable ledger under ContextBudget.
    beForceRawContext :: !Bool,
    -- | Config-level debug default; sessions override via @!debug@.
    beDebugDefault :: !Bool,
    -- | Config-level sticker default; sessions override via @!sticker
    -- on/off@.  When off, the @send_sticker@ tool isn't registered.
    beStickerDefault :: !Bool,
    -- | Default LLM profile name for new sessions / NULL model rows.
    beDefaultModel :: !Text,
    -- | Display timezone for model/user-facing timestamps ('AppConfig.timezone').
    beTimeZone :: !TimeZone,
    -- | When this process started (for @!version@'s bot uptime).
    beStartedAt :: !UTCTime,
    beSessions :: !SessionRegistry,
    -- | Skill packs (global + per-group): the write-through registry
    -- behind the system prompt's 技能对照表, the @use_skill@ tool and
    -- the admin API's @\/api\/skills@.  Loaded whole at boot
    -- ('Max.Skills.loadSkills').
    beSkills :: !SkillRegistry,
    beTasks :: !TaskRegistry,
    -- | Graceful-shutdown gate: 'Max.Handler.dispatchLLM' claims a slot
    -- here so SIGTERM can wait out the dispatches already running, and
    -- declines to start once draining.  See "Max.Shutdown".
    beShutdown :: !ShutdownState,
    -- | Bot owners' QQ ids ('AppConfig.owners') — the top permission
    -- tier for the command DSL.
    beOwners :: ![Int64],
    -- | Private-chat admin console state: per-user target group set
    -- by @!use \<群号\>@ — commands issued in that user's DMs act on
    -- the target instead of the DM pseudo-group.  In-memory by
    -- design (restart forgets; just @!use@ again).
    beAdminTarget :: !(TVar (Map Int64 Int64)),
    beSandboxes :: !SandboxRegistry,
    beBrowsers :: !BrowserRegistry,
    -- | Write-through bell behind ADR 006 monitor-backed reminder tools and
    -- the unified scheduler worker.
    beMonitors :: !MonitorScheduler,
    -- | Web-search backend when configured ('Nothing' = the
    -- @web_search@ tool isn't registered).
    beSearch :: !(Maybe SearchConfig),
    -- | Management access to the credential pool serving our LLM base
    -- URL ('Nothing' = @\/api\/quota@ reports itself unconfigured).
    beCliProxy :: !(Maybe CliProxyConfig),
    -- | Profile for Historian v2 episode capture ('Nothing' = off).  The
    -- configuration key retains its legacy memory-extract name.
    beMemoryExtract :: !(Maybe Text),
    -- | Quiet-period episode scheduler, present iff 'beMemoryExtract' is:
    -- dispatches arm its idle timer, incoming messages push it back
    -- ("Max.EpisodeScheduler").
    beEpisodeScheduler :: !(Maybe EpisodeScheduler),
    -- | Proactive-trigger intent config ('Nothing' = feature off).
    -- Dispatch itself lives in the intent worker; this handle is for
    -- the @!proactive@ command's status display.
    beIntent :: !(Maybe IntentConfig),
    -- | Capability flag used only for product gating/status.  Embedding calls
    -- themselves go through 'Max.Effects.Embedding'.
    beEmbeddingEnabled :: !Bool
  }
