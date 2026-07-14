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

import Data.Text (Text)
import Max.Browser.Registry (BrowserRegistry)
import Max.Sandbox.Registry (SandboxRegistry)
import Max.Session (SessionRegistry)
import Max.Tasks (TaskRegistry)

data BotEnv = BotEnv
  { -- | Persona used when a session hasn't overridden it ('AppConfig.persona').
    bePersona :: !Text,
    -- | Ambient history window size ('AppConfig.historyWindow').
    beHistoryWindow :: !Int,
    -- | Blob store root ('AppConfig.imagesDir'); image local paths are
    -- relative to it.
    beBlobRoot :: !FilePath,
    -- | Config-level debug default; sessions override via @!debug@.
    beDebugDefault :: !Bool,
    -- | Default LLM profile name for new sessions / NULL branch rows.
    beDefaultModel :: !Text,
    beSessions :: !SessionRegistry,
    beTasks :: !TaskRegistry,
    beSandboxes :: !SandboxRegistry,
    beBrowsers :: !BrowserRegistry,
    -- | Profile for post-dispatch memory extraction ('Nothing' = off).
    beMemoryExtract :: !(Maybe Text)
  }
