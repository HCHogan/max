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
module Max.Toolset
  ( allToolsFor,
    plannableToolsFor,
    toolCountFor,
    toolDefinitionsFor,
    toolAllowedByEffectCeiling,
    defaultToolDeadline,
  )
where

import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Set qualified as Set
import Data.Text (Text)
import Effectful
import Effectful.Concurrent (Concurrent)
import Effectful.Log (Log)
import Effectful.PostgreSQL (WithConnection)
import Max.Effects.Blob (Blob)
import Max.Effects.Embedding (Embedding)
import Max.Effects.Http (Http)
import Max.Effects.Outbound (Outbound)
import Max.Effects.PlatformApi (PlatformApi)
import Max.Effects.ToolOutput (ToolOutput)
import Max.Effects.Tools
  ( SchemaVersion (..),
    Tool (..),
    ToolAuthority (..),
    ToolCatalog,
    ToolCatalogError,
    ToolDeadline (..),
    ToolDefinition (..),
    ToolEffect (..),
    ToolParallelism (..),
    ToolRef (..),
    ToolRetryClass (..),
    buildToolCatalog,
  )
import Max.Env (BotEnv (..), applyRuntimeSnapshot)
import Max.HttpRuntime (HttpRuntime)
import Max.Platform.Types (noAdvertisedCaps)
import Max.ToolContext (ToolContext, TurnCapabilities (..), toolCapabilities, toolGroupId, toolMultimodal, toolRuntimeSnapshot, toolStickers)
import Max.Tools (builtinsFor)
import Max.Tools.Bilibili (bilibiliToolsFor)
import Max.Tools.Browser (browserToolsFor)
import Max.Tools.Files (fileToolsFor)
import Max.Tools.Group (groupToolsFor)
import Max.Tools.Images (imageToolsFor)
import Max.Tools.Memory (memoryToolsFor)
import Max.Tools.Monitor (monitorToolsFor)
import Max.Tools.Pins (pinToolsFor)
import Max.Tools.Plan (durablePlanJournal, planToolsFor, plannableSubCatalog)
import Max.Tools.Reminder (reminderToolsFor)
import Max.Tools.Sandbox (sandboxToolsFor)
import Max.Tools.Search (searchToolsFor)
import Max.Tools.Skills (skillToolsFor)
import Max.Tools.Stickers (stickerToolsFor)
import Max.Tools.Subgoal (subgoalToolsFor)
import Max.Tools.Task (guardTaskResource, taskToolsFor)
import Max.Tools.Video (videoToolsFor)
import Max.Turn.Continuity (toolCatalogFingerprint)
import OneBot.Types (GroupId, isPrivateChat)

-- | The tool list for one dispatch.
--
-- Three things are decided per dispatch rather than per process: the
-- sticker toggle (session-level @!sticker@), and the two toolsets that
-- only make sense on a profile that can see — a text-only model given
-- a browser or a video reader would burn turns discovering it can't
-- use them.
allToolsFor ::
  ( Blob :> es,
    Http :> es,
    Embedding :> es,
    Log :> es,
    Concurrent :> es,
    PlatformApi :> es,
    Outbound :> es,
    ToolOutput :> es,
    WithConnection :> es,
    IOE :> es
  ) =>
  HttpRuntime ->
  BotEnv ->
  ToolContext ->
  Either ToolCatalogError (ToolCatalog es)
allToolsFor runtime env dc =
  buildToolCatalog definitions runners
  where
    (definitions, base) = resolvedToolsFor runtime env dc
    allowedRefs = Set.fromList [definition'.tdRef.unToolRef | definition' <- definitions]
    -- The plan runners are built from the tools this dispatch already resolved
    -- — a plan calls them through a sub-catalog of exactly these — so they can
    -- only be assembled after the gate has run, and then get filtered by the
    -- same gate themselves.
    runners = base <> filter allowedRunner (planToolsFor (durablePlanJournal dc) definitions base)
    allowedRunner tool = tool.toolName `Set.member` allowedRefs

-- | The sub-catalog a suspended plan resumes into.
--
-- ADR 007 §11. A plan that parked at a fork continues in a worker rather than
-- in the turn that wrote it, and it has to reach the same tools it would have
-- reached inline — same gates, same effect ceiling, same subset — or a plan
-- admitted against one catalog would execute against another.
--
-- It is the plannable subset and nothing else, which also means a resumed plan
-- cannot speak: no tool in that subset sends.
plannableToolsFor ::
  ( Blob :> es,
    Http :> es,
    Embedding :> es,
    Log :> es,
    PlatformApi :> es,
    Outbound :> es,
    ToolOutput :> es,
    WithConnection :> es,
    IOE :> es
  ) =>
  HttpRuntime ->
  BotEnv ->
  ToolContext ->
  Either ToolCatalogError (ToolCatalog es)
plannableToolsFor runtime env dc = uncurry plannableSubCatalog (resolvedToolsFor runtime env dc)

-- | The gated definitions and the gated runners, which every catalog in this
-- module is a selection of.
resolvedToolsFor ::
  ( Blob :> es,
    Http :> es,
    Embedding :> es,
    Log :> es,
    PlatformApi :> es,
    Outbound :> es,
    ToolOutput :> es,
    WithConnection :> es,
    IOE :> es
  ) =>
  HttpRuntime ->
  BotEnv ->
  ToolContext ->
  ([ToolDefinition], [Tool es])
resolvedToolsFor runtime env dc = (definitions, map (guardTaskResource dc) (filter allowedRunner runners0))
  where
    dispatchEnv = maybe env (`applyRuntimeSnapshot` env) (toolRuntimeSnapshot dc)
    definitions = toolDefinitionsFor dispatchEnv (toolGroupId dc) (toolCapabilities dc)
    allowedRefs = Set.fromList [definition'.tdRef.unToolRef | definition' <- definitions]
    allowedRunner tool = tool.toolName `Set.member` allowedRefs
    runners0 =
      builtinsFor dispatchEnv.beTimeZone dc
        <> reminderToolsFor dispatchEnv.beTimeZone dc
        <> monitorToolsFor dispatchEnv.beTimeZone dc
        <> groupToolsFor dc
        <> imageToolsFor dispatchEnv.beTimeZone dc
        <> memoryToolsFor dc
        <> pinToolsFor dispatchEnv.beSessions dispatchEnv.beDefaultModel dc
        <> subgoalToolsFor dc
        <> taskToolsFor dc
        <> skillToolsFor dispatchEnv.beSkills dc
        <> bilibiliToolsFor dispatchEnv.beTimeZone dc
        <> sandboxToolsFor dispatchEnv.beTimeZone (toolGroupId dc) dispatchEnv.beSandboxes
        <> fileToolsFor dispatchEnv.beTimeZone dc dispatchEnv.beSandboxes
        <> [t | toolStickers dc && dispatchEnv.beEmbeddingEnabled, t <- stickerToolsFor]
        <> maybe [] (searchToolsFor runtime) dispatchEnv.beSearch
        <> [t | toolMultimodal dc, t <- browserToolsFor dc dispatchEnv.beBrowsers dispatchEnv.beBrowserProxy]
        <> [t | toolMultimodal dc, t <- videoToolsFor dc]

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
  length (toolDefinitionsFor env gid (TurnCapabilities multimodal stickers skills noAdvertisedCaps True Map.empty Nothing Nothing False))

-- | Product-level visibility and effect metadata live in one inventory.  The
-- actual runners assembled above must match this filtered set exactly or
-- 'buildToolCatalog' rejects the dispatch before the model sees a schema.
toolDefinitionsFor :: BotEnv -> GroupId -> TurnCapabilities -> [ToolDefinition]
toolDefinitionsFor env gid caps =
  [ item.tiDefinition
  | item <- toolInventory,
    gateOpen item.tiGate,
    ceilingOpen item.tiDefinition
  ]
  where
    gateOpen = \case
      Always -> True
      GroupOnly -> not (isPrivateChat gid)
      MultimodalOnly -> caps.tcMultimodal
      StickersOnly -> caps.tcStickers && env.beEmbeddingEnabled
      SkillsOnly -> caps.tcSkills
      SearchOnly -> isJust env.beSearch
      MonitorArmOnly -> caps.tcMonitorArming
      SubgoalOnly -> isJust caps.tcSubgoal
      BackgroundOnly -> caps.tcBackground
      LegacyPlanOnly -> isJust caps.tcSubgoal || isJust caps.tcEffectCeiling && not caps.tcBackground
    ceilingOpen definition' =
      (caps.tcBackground && definition'.tdRef == ToolRef "task_finish")
        || toolAllowedByEffectCeiling caps.tcEffectCeiling definition'

-- | Exact grant intersection for a standing continuation. A matching name is
-- insufficient: schema, effects, retry class and authorities must retain the
-- same fingerprint they had when the monitor was armed.
toolAllowedByEffectCeiling :: Maybe (Map.Map Text Text) -> ToolDefinition -> Bool
toolAllowedByEffectCeiling effectCeiling definition' =
  maybe
    True
    (\grants -> Map.lookup definition'.tdRef.unToolRef grants == Just (toolCatalogFingerprint [definition']))
    effectCeiling

data ToolGate
  = Always
  | GroupOnly
  | MultimodalOnly
  | StickersOnly
  | SkillsOnly
  | SearchOnly
  | MonitorArmOnly
  | BackgroundOnly
  | LegacyPlanOnly
  | -- | Only a fork child, which is the only turn that has somewhere to
    -- return a value to.
    SubgoalOnly

data ToolInventoryItem = ToolInventoryItem
  { tiGate :: !ToolGate,
    tiDefinition :: !ToolDefinition
  }

toolInventory :: [ToolInventoryItem]
toolInventory =
  [ -- The one act a fork child performs that an ordinary turn cannot, and the
    -- only way a child can succeed at all.
    gated SubgoalOnly (writeTool "subgoal_return" ["plan.children"] [CurrentConversation]),
    always (readTool "inspect_source" ["self.source"] [ProcessResource "self-source"]),
    always (readTool "get_message_by_id" ["conversation.db"] [CurrentConversation]),
    always (llmReadTool "context_search" ["conversation.db"] [CurrentConversation]),
    always (readToolV 2 "context_expand" ["conversation.db"] [CurrentConversation]),
    always (readTool "view_forward" ["conversation.db"] [CurrentConversation]),
    always (sendTool "poke" "chat.endpoint"),
    -- An explicit reminder is the asker's own standing consent, not
    -- bot-initiated activity: it stays open to every member.  Only
    -- 'arm_monitor', which opens turns nobody asked for at that moment,
    -- carries the role gate (ADR 006 "quietness is structural").
    -- Audited: bad args, empty text and every resolveWhen rejection all return
    -- before armCannedTimeMonitor is reached.
    always (failsBeforeEffects (writeToolV 2 "set_reminder" ["monitor.db"] [CurrentConversation])),
    always (readToolV 2 "list_reminders" ["monitor.db"] [CurrentConversation]),
    always (writeToolV 2 "cancel_reminder" ["monitor.db"] [CurrentConversation]),
    gated MonitorArmOnly (writeToolV 1 "arm_monitor" ["monitor.db"] [CurrentConversation]),
    always (readToolV 1 "list_monitors" ["monitor.db"] [CurrentConversation]),
    always (writeToolV 2 "cancel_monitor" ["monitor.db"] [CurrentConversation]),
    always (writeTool "configure_monitor" ["monitor.db"] [CurrentConversation]),
    always (readTool "monitor_history" ["monitor.db"] [CurrentConversation]),
    gated GroupOnly (readTool "group_members" ["chat.roster"] [CurrentConversation, CurrentEndpoint]),
    gated MultimodalOnly (statefulReadTool "view_avatar" ["chat.avatar", "tool.media"] [CurrentConversation, CurrentEndpoint]),
    gated MultimodalOnly (statefulReadTool "view_image" ["conversation.db", "blob.store", "tool.media"] [CurrentConversation]),
    always (writeTool "memory_save" ["memory.db"] [CurrentConversation]),
    always (writeTool "memory_update" ["memory.db"] [CurrentConversation]),
    always (writeTool "memory_forget" ["memory.db"] [CurrentConversation]),
    always (readTool "memory_list" ["memory.db"] [CurrentConversation]),
    always (writeTool "pin_message" ["session.db"] [CurrentConversation]),
    always (writeTool "unpin_message" ["session.db"] [CurrentConversation]),
    gated SkillsOnly (reflectTool "use_skill"),
    gated LegacyPlanOnly (reflectTool "plan_guide"),
    gated LegacyPlanOnly (readTool "plan_list" ["plan.db"] [CurrentConversation]),
    gated LegacyPlanOnly (writeTool "plan_revise" ["plan.db"] [CurrentConversation]),
    always (writeTool "task_start" ["task.db"] [CurrentConversation]),
    always (readTool "task_list" ["task.db"] [CurrentConversation]),
    always (readTool "task_status" ["task.db"] [CurrentConversation]),
    always (writeTool "task_steer" ["task.db"] [CurrentConversation]),
    always (writeTool "task_replace" ["task.db"] [CurrentConversation]),
    always (writeTool "task_cancel" ["task.db"] [CurrentConversation]),
    gated BackgroundOnly (writeTool "task_finish" ["task.db"] [CurrentConversation]),
    -- The union of what 'Max.Plan.Catalog' declares plannable, stated
    -- statically because the inventory cannot vary with it.  Over-declaring
    -- when search is unconfigured is the conservative direction: an effect
    -- ceiling that would refuse the search a plan might make should refuse the
    -- plan tool too, rather than let it through and find out inside.
    gated LegacyPlanOnly (definition "plan_run" [EffectRead "network.search", EffectRead "conversation.db"] SequentialOnly RetryUnsafe [CurrentConversation]),
    -- Queues turn-scoped inline video as well as reading the network.  Keep it
    -- sequential inside one agent round so concurrent calls cannot race the
    -- shared attachment order/budget; independent turns have independent
    -- ToolOutput interpreters and still run concurrently.
    always (statefulReadTool "view_bilibili" ["network.bilibili", "tool.media"] [CurrentConversation]),
    always (writeTool "sandbox_create" ["sandbox.lifecycle"] [CurrentConversation, ProcessResource "sandbox"]),
    -- The model picks this one's timeout itself, clamped to ten minutes, and
    -- 'timeout --preserve-status' enforces it inside the container.  What that
    -- cannot bound is the host side: 'docker exec' wedging leaves the call
    -- hanging with the command already finished or never started.  So this is
    -- the container's own ceiling plus enough slack to be sure the difference
    -- is docker's and not the command's.  It sits above the turn watchdog on
    -- purpose — for a front-model turn that watchdog fires first, and this is
    -- here for the plan executor, which has no such thing over it.
    always (withDeadline 660 (writeTool "sandbox_exec" ["sandbox.process", "sandbox.fs"] [CurrentConversation, ProcessResource "sandbox"])),
    -- Same container mechanism, fixed 120s inside; the slack is the same idea.
    always (withDeadline 180 (statefulReadTool "nix_search" ["sandbox.process", "network.nix"] [CurrentConversation, ProcessResource "sandbox"])),
    always (statefulReadTool "sandbox_list" ["sandbox.registry"] [CurrentConversation, ProcessResource "sandbox"]),
    always (writeTool "sandbox_destroy" ["sandbox.lifecycle"] [CurrentConversation, ProcessResource "sandbox"]),
    always (statefulReadTool "sandbox_read_file" ["sandbox.fs"] [CurrentConversation, ProcessResource "sandbox"]),
    always (writeTool "sandbox_write_file" ["sandbox.fs"] [CurrentConversation, ProcessResource "sandbox"]),
    always (readTool "list_recent_files" ["conversation.db", "blob.store"] [CurrentConversation]),
    always (writeTool "import_file_to_sandbox" ["blob.store", "sandbox.fs"] [CurrentConversation, ProcessResource "sandbox"]),
    always (sendReadTool "send_image_from_sandbox" ["sandbox.fs"]),
    always (sendReadTool "send_file_from_sandbox" ["sandbox.fs"]),
    gated StickersOnly (llmReadTool "find_stickers" ["sticker.db"] [CurrentConversation]),
    gated SearchOnly (readTool "web_search" ["network.search"] [CurrentConversation]),
    gated MultimodalOnly (browserTool "browser_navigate"),
    gated MultimodalOnly (browserTool "view_zhihu"),
    gated MultimodalOnly (browserTool "browser_snapshot"),
    gated MultimodalOnly (browserTool "browser_click"),
    gated MultimodalOnly (browserTool "browser_type"),
    gated MultimodalOnly (browserTool "browser_press_key"),
    gated MultimodalOnly (browserTool "browser_wait_for"),
    gated MultimodalOnly (browserTool "browser_scroll"),
    gated MultimodalOnly (statefulReadTool "view_video" ["conversation.db", "blob.store", "tool.media"] [CurrentConversation])
  ]

always :: ToolDefinition -> ToolInventoryItem
always = gated Always

gated :: ToolGate -> ToolDefinition -> ToolInventoryItem
gated = ToolInventoryItem

definition :: Text -> [ToolEffect] -> ToolParallelism -> ToolRetryClass -> [ToolAuthority] -> ToolDefinition
definition name effects parallelism retry authorities =
  ToolDefinition
    { tdRef = ToolRef name,
      tdSchemaVersion = SchemaVersion 1,
      tdEffects = Set.fromList effects,
      tdParallelism = parallelism,
      tdRetryClass = retry,
      tdAuthorities = Set.fromList authorities,
      tdDeadline = defaultToolDeadline,
      tdFailuresPrecedeEffects = False
    }

-- | What a tool gets unless it says otherwise.
--
-- Sized off what the catalog actually does rather than off a round number.
-- Over thirty days of production every tool but three finished inside ten
-- seconds at its worst; the three that did not say so below.  So this is not
-- a performance budget — it is the point past which a tool is not slow, it is
-- stuck, and the alternatives to noticing that are all worse: the caller waits
-- on the unbounded HTTP paths (browser RPC, and the byte fetches behind
-- @view_image@ and friends) until the turn's own watchdog kills the whole
-- turn, several minutes later, with nothing to show the model.
defaultToolDeadline :: ToolDeadline
defaultToolDeadline = ToolDeadline 120

-- | Override for the tools whose work is legitimately long.
withDeadline :: Int -> ToolDefinition -> ToolDefinition
withDeadline seconds definition' = definition' {tdDeadline = ToolDeadline seconds}

-- | Record that a tool has been read and every error path in it precedes every
-- effect, so a rejection can be reported as a plain failure the model may fix
-- and retry rather than as an outcome it must not assume anything about.
--
-- Per-tool and opt-in on purpose: it is a claim about one implementation, and
-- it stops being true the moment someone moves a write above a validation.
failsBeforeEffects :: ToolDefinition -> ToolDefinition
failsBeforeEffects definition' = definition' {tdFailuresPrecedeEffects = True}

readTool :: Text -> [Text] -> [ToolAuthority] -> ToolDefinition
readTool name domains =
  definition name (map EffectRead domains) ParallelSafe RetrySafe

readToolV :: Int -> Text -> [Text] -> [ToolAuthority] -> ToolDefinition
readToolV version name domains authorities =
  (readTool name domains authorities) {tdSchemaVersion = SchemaVersion version}

statefulReadTool :: Text -> [Text] -> [ToolAuthority] -> ToolDefinition
statefulReadTool name domains =
  definition name (map EffectRead domains) SequentialOnly RetrySafe

writeTool :: Text -> [Text] -> [ToolAuthority] -> ToolDefinition
writeTool name domains =
  definition name (map EffectWrite domains) SequentialOnly RetryUnsafe

writeToolV :: Int -> Text -> [Text] -> [ToolAuthority] -> ToolDefinition
writeToolV version name domains authorities =
  (writeTool name domains authorities) {tdSchemaVersion = SchemaVersion version}

llmReadTool :: Text -> [Text] -> [ToolAuthority] -> ToolDefinition
llmReadTool name domains =
  definition name (EffectLLM : map EffectRead domains) SequentialOnly RetryUnsafe

sendTool :: Text -> Text -> ToolDefinition
sendTool name domain =
  definition name [EffectSend domain] SequentialOnly RetryUnsafe [CurrentConversation, CurrentEndpoint]

sendReadTool :: Text -> [Text] -> ToolDefinition
sendReadTool name domains =
  definition
    name
    (EffectSend "chat.endpoint" : map EffectRead domains)
    SequentialOnly
    RetryUnsafe
    [CurrentConversation, CurrentEndpoint, ProcessResource "sandbox"]

reflectTool :: Text -> ToolDefinition
reflectTool name =
  definition name [EffectReflect] SequentialOnly RetryUnsafe [CurrentConversation]

-- | Browser calls carry the catalog's only genuinely unbounded wait: the MCP
-- client sets no response timeout and inherits none from the manager, so a
-- browser container that stops answering never returns.  The bound is set off
-- the worst real navigation observed (193s, a page that took three minutes to
-- settle) rather than the median (7s), because a slow page is the normal case
-- this must not interrupt.
browserTool :: Text -> ToolDefinition
browserTool name =
  withDeadline 240 $
    definition
      name
      [EffectWrite "browser.session", EffectRead "network.web"]
      SequentialOnly
      RetryUnsafe
      [CurrentConversation, ProcessResource "browser"]
