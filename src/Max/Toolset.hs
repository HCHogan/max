-- |
-- Everything the agent can do, assembled in one place.
--
-- The list lives here rather than in @Main@ because "what tools does
-- this bot have" is a question about the bot, not about process
-- startup; reading it should not mean reading past a DB pool and a
-- signal handler.  It takes 'BotEnv' rather than a dozen loose handles
-- for the same reason — the registries and config it needs are already
-- what every other layer reaches for.
--
-- Not in "Max.Tools": that module is imported by "Max.Tools.Reminder",
-- so assembling the full set there would close a cycle.
module Max.Toolset (allToolsFor, toolCountFor) where

import Data.Text (Text)
import Effectful
import Effectful.Log (Log)
import Effectful.PostgreSQL (WithConnection)
import Effectful.Wreq qualified as W
import Max.Effects.Http (Http)
import Max.Effects.NapCat (NapCat)
import Max.Effects.Outbound (Outbound)
import Max.Effects.ToolOutput (ToolOutput)
import Max.Effects.Tools (Tool)
import Max.Env (BotEnv (..))
import Max.Tools (builtinsFor)
import Max.Tools.Bilibili (bilibiliToolsFor)
import Max.Tools.Browser (browserToolsFor)
import Max.Tools.Files (fileToolsFor)
import Max.Tools.Group (groupToolsFor)
import Max.Tools.Images (imageToolsFor)
import Max.Tools.Memory (memoryToolsFor)
import Max.Tools.Pins (pinToolsFor)
import Max.Tools.Reminder (reminderToolsFor)
import Max.Tools.Sandbox (sandboxToolsFor)
import Max.Tools.Search (searchToolsFor)
import Max.Tools.Skills (skillToolsFor)
import Max.Tools.Stickers (stickerToolsFor)
import Max.Tools.Video (videoToolsFor)
import Max.ToolContext (ToolContext, TurnCapabilities (..), toolGroupId, toolMultimodal, toolSelfId, toolStickers)
import OneBot.Types (GroupId, isPrivateChat)

-- | The tool list for one dispatch.
--
-- Three things are decided per dispatch rather than per process: the
-- sticker toggle (session-level @!sticker@), and the two toolsets that
-- only make sense on a profile that can see — a text-only model given
-- a browser or a video reader would burn turns discovering it can't
-- use them.
allToolsFor ::
  ( Http :> es,
    Log :> es,
    NapCat :> es,
    Outbound :> es,
    ToolOutput :> es,
    W.Wreq :> es,
    WithConnection :> es,
    IOE :> es
  ) =>
  BotEnv ->
  ToolContext ->
  [Tool es]
allToolsFor env dc =
  builtinsFor env.beTimeZone env.beEmbed dc
    <> reminderToolsFor env.beTimeZone env.beReminders dc
    <> groupToolsFor dc
    <> imageToolsFor env.beTimeZone env.beBlobRoot dc
    <> memoryToolsFor env.beEmbed dc
    <> pinToolsFor env.beSessions env.beDefaultModel dc
    <> skillToolsFor env.beSkills dc
    <> bilibiliToolsFor env.beTimeZone dc
    <> sandboxToolsFor env.beTimeZone (toolGroupId dc) env.beSandboxes
    <> fileToolsFor env.beTimeZone (toolGroupId dc) (toolSelfId dc) env.beBlobRoot env.beSandboxes
    <> [t | toolStickers dc, t <- stickerToolsFor env.beEmbed]
    <> maybe [] searchToolsFor env.beSearch
    <> [t | toolMultimodal dc, t <- browserToolsFor (toolGroupId dc) env.beBrowsers]
    <> [t | toolMultimodal dc, t <- videoToolsFor env.beBlobRoot]

-- | How many tools a dispatch with these gates would get — the
-- @!version@ card's number.  This is intentionally a pure projection
-- of the same gates as 'allToolsFor': reporting capabilities must not
-- manufacture fake turn identities or mutable output queues.
toolCountFor ::
  BotEnv ->
  GroupId ->
  Bool -> -- multimodal profile
  Bool -> -- stickers effective
  Bool -> -- skills visible
  Int
toolCountFor env gid multimodal stickers skills =
  length (toolNamesFor env gid (TurnCapabilities multimodal stickers skills))

-- Keep the live registration order visible here.  Adding or removing a tool
-- requires updating this projection; unlike constructing live 'Tool' values,
-- it cannot accidentally acquire effects or demand fabricated ids.
toolNamesFor :: BotEnv -> GroupId -> TurnCapabilities -> [Text]
toolNamesFor env gid caps =
  [ "get_message_by_id",
    "search_messages",
    "view_forward",
    "poke",
    "set_reminder",
    "list_reminders",
    "cancel_reminder"
  ]
    <> ["group_members" | not (isPrivateChat gid)]
    <> [name | caps.tcMultimodal, name <- ["view_avatar", "view_image"]]
    <> ["memory_save", "memory_update", "memory_forget", "memory_list"]
    <> ["memory_search" | Just _ <- [env.beEmbed]]
    <> ["pin_message", "unpin_message"]
    <> ["use_skill" | caps.tcSkills]
    <> ["view_bilibili"]
    <> [ "sandbox_create",
         "sandbox_exec",
         "nix_search",
         "sandbox_list",
         "sandbox_destroy",
         "sandbox_read_file",
         "sandbox_write_file"
       ]
    <> [ "list_recent_files",
         "import_file_to_sandbox",
         "send_image_from_sandbox",
         "send_file_from_sandbox"
       ]
    <> ["find_stickers" | caps.tcStickers, Just _ <- [env.beEmbed]]
    <> ["web_search" | Just _ <- [env.beSearch]]
    <> [ name
       | caps.tcMultimodal,
         name <-
           [ "browser_navigate",
             "view_zhihu",
             "browser_snapshot",
             "browser_click",
             "browser_type",
             "browser_press_key",
             "browser_wait_for",
             "browser_scroll",
             "view_video"
           ]
       ]
