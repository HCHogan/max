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

import Control.Concurrent.STM (newTVarIO)
import Effectful
import Effectful.Log (Log)
import Effectful.PostgreSQL (WithConnection)
import Effectful.Wreq qualified as W
import Max.Effects.Agent (DispatchContext (..))
import Max.Effects.Http (Http)
import Max.Effects.NapCat (NapCat)
import Max.Effects.Outbound (Outbound)
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
import OneBot.Types (GroupId, MessageId (..), UserId (..))

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
    W.Wreq :> es,
    WithConnection :> es,
    IOE :> es
  ) =>
  BotEnv ->
  DispatchContext ->
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
    <> sandboxToolsFor env.beTimeZone dc.dcGroupId env.beSandboxes
    <> fileToolsFor env.beTimeZone dc.dcGroupId dc.dcSelfId env.beBlobRoot env.beSandboxes
    <> [t | dc.dcStickers, t <- stickerToolsFor env.beEmbed]
    <> maybe [] searchToolsFor env.beSearch
    <> [t | dc.dcMultimodal, t <- browserToolsFor dc.dcGroupId env.beBrowsers]
    <> [t | dc.dcMultimodal, t <- videoToolsFor env.beBlobRoot dc]

-- | How many tools a dispatch with these gates would get — the
-- @!version@ card's number.  The context is a throwaway (ids zeroed,
-- a fresh image TVar): the list's shape depends only on the gate
-- booleans and 'BotEnv', and nothing here ever runs a tool.  The
-- element type is pinned to an arbitrary concrete stack because
-- @(:>)@ only asks for membership — no interpreters are involved.
toolCountFor ::
  BotEnv ->
  GroupId ->
  Bool -> -- multimodal profile
  Bool -> -- stickers effective
  Bool -> -- skills visible
  IO Int
toolCountFor env gid multimodal stickers skills = do
  imgs <- newTVarIO (0, [])
  let dc =
        DispatchContext
          { dcGroupId = gid,
            dcMessageId = MessageId 0,
            dcUserId = UserId 0,
            dcSelfId = UserId 0,
            dcMultimodal = multimodal,
            dcStickers = stickers,
            dcSkills = skills,
            dcEffort = Nothing,
            dcToolImages = imgs
          }
  pure (length (allToolsFor env dc :: [Tool '[Http, Log, NapCat, Outbound, W.Wreq, WithConnection, IOE]]))
