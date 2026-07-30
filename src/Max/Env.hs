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
-- 'Max.Effects.Agent.DispatchContext'.
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
import Max.Embedding (EmbedClient)
import Max.Intent (IntentConfig)
import Max.MemoryExtract (MemxScheduler)
import Max.Reminder (ReminderScheduler)
import Max.Sandbox.Registry (SandboxRegistry)
import Max.Session (SessionRegistry)
import Max.Skills (SkillRegistry)
import Max.Tools.Search (SearchConfig)
import Max.Shutdown (ShutdownState)
import Max.Tasks (TaskRegistry)

data BotEnv = BotEnv
  { -- | Persona used when a session hasn't overridden it ('AppConfig.persona').
    bePersona :: !Text,
    -- | Transcript low-water mark (see 'Max.Config.historyWindow').
    beHistoryWindow :: !Int,
    -- | Transcript high-water mark (see 'Max.Config.historyMax').
    beHistoryMax :: !Int,
    -- | Blob store root ('AppConfig.imagesDir'); image local paths are
    -- relative to it.
    beBlobRoot :: !FilePath,
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
    -- | Scheduler behind the reminder tools and the reminder worker.
    beReminders :: !ReminderScheduler,
    -- | Web-search backend when configured ('Nothing' = the
    -- @web_search@ tool isn't registered).
    beSearch :: !(Maybe SearchConfig),
    -- | Profile for episode memory extraction ('Nothing' = off).
    beMemoryExtract :: !(Maybe Text),
    -- | The extraction scheduler, present iff 'beMemoryExtract' is:
    -- dispatches arm its idle timer, incoming messages push it back
    -- ("Max.MemoryExtract").
    beMemx :: !(Maybe MemxScheduler),
    -- | Proactive-trigger intent config ('Nothing' = feature off).
    -- Dispatch itself lives in the intent worker; this handle is for
    -- the @!proactive@ command's status display.
    beIntent :: !(Maybe IntentConfig),
    -- | Embeddings client when configured — the extractor uses it for
    -- semantic dedup of new memories.
    beEmbed :: !(Maybe EmbedClient)
  }
