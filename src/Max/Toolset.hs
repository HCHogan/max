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
    toolCountFor,
    toolDefinitionsFor,
    skillToolDefinitions,
    toolAllowedByEffectCeiling,
    defaultToolDeadline,
  )
where

import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust, isNothing)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Effectful
import Effectful.Log (Log)
import Effectful.PostgreSQL (WithConnection)
import Max.Browser.ToolRuntime (browserToolsFor)
import Max.CodeMode.JavaScript (javaScriptRuntimeVersion)
import Max.Conversation.ToolRuntime (builtinsWithDatabase, groupToolsWithDatabase)
import Max.Effects.Blob (Blob)
import Max.Effects.BlobHost (BlobHost)
import Max.Effects.Embedding (Embedding)
import Max.Effects.Http (Http)
import Max.Effects.Outbound (Outbound)
import Max.Effects.PlatformInteraction (PlatformInteraction)
import Max.Effects.PlatformQuery (PlatformQuery)
import Max.Effects.ToolControl (ToolControl)
import Max.Effects.ToolOutput (ToolOutput)
import Max.Effects.Tools
  ( SchemaVersion (..),
    Tool (..),
    ToolAuthority (..),
    ToolCatalogError,
    ToolDeadline (..),
    ToolDefinition (..),
    ToolEffect (..),
    ToolParallelism (..),
    ToolRef (..),
    ToolRegistry,
    ToolRetryClass (..),
    buildToolRegistry,
    registryCatalog,
  )
import Max.Env (BotEnv (..), applyRuntimeSnapshot)
import Max.File.ToolRuntime (fileToolsWithDatabase)
import Max.HttpRuntime (HttpRuntime)
import Max.MaxOps.Client (maxOpsOperations)
import Max.MaxOps.Protocol (Catalog (..), CatalogAccess (..), Operation (..), catalogForSkill, catalogValue, operationToolName, parseCatalog)
import Max.MaxOps.TaskRuntime (admitMaxOpsTask)
import Max.MaxOps.Types (maxOpsAllowed)
import Max.Media.ToolRuntime (imageToolsWithDatabase, stickerToolsWithDatabase, videoToolsWithDatabase)
import Max.Memory.ToolRuntime (memoryToolsWithDatabase)
import Max.Monitor.ToolRuntime (monitorToolsWithDatabase, reminderToolsWithDatabase)
import Max.Pin.ToolRuntime (pinToolsWithDatabase)
import Max.Platform.Types (noAdvertisedCaps)
import Max.RuntimeConfig (RuntimeSnapshot (..), RuntimeValues (..), currentRuntimeSnapshot)
import Max.Skill.ToolRuntime (skillAuthoringToolsWithDatabase)
import Max.Skill.Workflow (bindWorkflowContracts)
import Max.Task.ToolRuntime (guardTaskResource, taskToolsWithDatabase)
import Max.Tool.Bundles (SkillLoad (..), toolBundle, toolVisible)
import Max.Tool.Catalog (catalogTools)
import Max.Tool.Types (ToolCallMode (..))
import Max.ToolContext (ToolContext, TurnCapabilities (..), toolCapabilities, toolGroupId, toolMultimodal, toolRuntimeSnapshot, toolSkillLoads, toolStickers, withToolSkillLoads)
import Max.Tools.Bilibili (bilibiliToolsFor)
import Max.Tools.MaxOps (maxOpsBundle)
import Max.Tools.Sandbox (sandboxToolsFor)
import Max.Tools.Search (searchToolsFor)
import Max.Tools.Skills (skillToolsFor)
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
  ( BlobHost :> es,
    Blob :> es,
    Http :> es,
    Embedding :> es,
    Log :> es,
    PlatformQuery :> es,
    PlatformInteraction :> es,
    Outbound :> es,
    ToolOutput :> es,
    ToolControl :> es,
    WithConnection :> es,
    IOE :> es
  ) =>
  HttpRuntime ->
  BotEnv ->
  ToolContext ->
  Either ToolCatalogError (ToolRegistry es)
allToolsFor runtime env dc = uncurry buildToolRegistry (resolvedToolsFor runtime env dc)

-- | The gated definitions and the gated runners, which every catalog in this
-- module is a selection of.
resolvedToolsFor ::
  forall es.
  ( BlobHost :> es,
    Blob :> es,
    Http :> es,
    Embedding :> es,
    Log :> es,
    PlatformQuery :> es,
    PlatformInteraction :> es,
    Outbound :> es,
    ToolOutput :> es,
    ToolControl :> es,
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
    authorized = toolDefinitionsFor dispatchEnv (toolGroupId dc) (toolCapabilities dc)
    definitions = filter (\definition' -> toolVisible (toolSkillLoads dc) definition'.tdRef.unToolRef && definition'.tdRef.unToolRef `notElem` ["maxops_operations", "maxops_query", "maxops_execute"]) authorized <> remoteDefinitions
    loadedOperations =
      [ entry
      | skill <- ["maxops", "maxops-changes"],
        Just value <- [Map.lookup skill (toolSkillLoads dc) >>= (.slMetadata) >>= (\case Object fields -> KeyMap.lookup "catalog" fields; _ -> Nothing)],
        Right catalog <- [parseCatalog value],
        entry <- (catalogForSkill skill catalog).operations
      ]
    remotePairs =
      [ (entry, marker)
      | entry <- loadedOperations,
        marker <- authorized,
        marker.tdRef == ToolRef (if entry.readOnly then "maxops_query" else "maxops_execute")
      ]
    remoteDefinitions =
      [ marker
          { tdRef = ToolRef (operationToolName entry),
            tdEffects = if entry.requiresKey then marker.tdEffects else Set.delete (EffectWrite "task.db") marker.tdEffects,
            tdRetryClass = if entry.requiresKey then RetryIdempotent else marker.tdRetryClass
          }
      | (entry, marker) <- remotePairs
      ]
    allowedRefs = Set.fromList [definition'.tdRef.unToolRef | definition' <- authorized]
    visibleRefs = Set.fromList [definition'.tdRef.unToolRef | definition' <- definitions]
    allowedRunner tool = tool.toolName `Set.member` visibleRefs
    prepareSkill skill | skill `elem` ["maxops", "maxops-changes"] = do
      current <- (.rsValues.rvMaxOps) <$> currentRuntimeSnapshot env.beConfigStore
      if current /= dispatchEnv.beMaxOps || not (maxOpsAllowed current (toolGroupId dc)) || not (any (`Set.member` allowedRefs) ["maxops_query", "maxops_execute"])
        then pure (Left "maxops access is unavailable or changed")
        else do
          fetched <- maxOpsOperations runtime current (if "maxops_execute" `Set.member` allowedRefs then ManagementCatalog else ReadOnlyCatalog)
          pure $ do
            value <- fetched
            catalog <- parseCatalog value
            let selected = catalogForSkill skill catalog
            if any ((== "jobs.wait") . (.name)) catalog.operations || not (any (.requiresKey) selected.operations)
              then Right (Just (object ["catalog" .= catalogValue ManagementCatalog selected, "availability" .= object ["tools" .= map operationToolName selected.operations, "unavailable" .= ([] :: [Text])]]))
              else Left "maxops 缺少 jobs.wait；请先更新 Hub，再加载完整工具包"
    prepareSkill "codemode" =
      pure (Right (Just (object ["availability" .= object ["tools" .= (["run_code"] :: [Text]), "unavailable" .= ([] :: [Text])]])))
    prepareSkill name =
      pure
        ( Right
            ( Just
                ( object
                    [ "availability"
                        .= object
                          [ "tools" .= [ref | ref <- Set.toList allowedRefs, toolBundle ref == Just name],
                            "unavailable"
                              .= [ item.tiDefinition.tdRef.unToolRef
                                 | item <- toolInventory,
                                   toolBundle item.tiDefinition.tdRef.unToolRef == Just name,
                                   item.tiDefinition.tdRef.unToolRef `Set.notMember` allowedRefs
                                 ],
                            "reason" .= ("工具受当前模型、平台配置和授权上限约束" :: Text)
                          ]
                    ]
                )
            )
        )
    authoringCatalog = do
      registry <- either (Left . T.pack . show) Right (allToolsFor runtime env dc :: Either ToolCatalogError (ToolRegistry es))
      Right (catalogTools (registryCatalog registry))
    bindPackages loads = do
      registry <- either (Left . T.pack . show) Right (allToolsFor runtime env (withToolSkillLoads loads dc) :: Either ToolCatalogError (ToolRegistry es))
      bindWorkflowContracts javaScriptRuntimeVersion (toolSkillLoads dc) (catalogTools (registryCatalog registry)) loads
    runners0 =
      builtinsWithDatabase dispatchEnv.beTimeZone dc
        <> reminderToolsWithDatabase dispatchEnv.beTimeZone dc
        <> monitorToolsWithDatabase dispatchEnv.beTimeZone dc
        <> groupToolsWithDatabase dc
        <> imageToolsWithDatabase dispatchEnv.beTimeZone dc
        <> memoryToolsWithDatabase dc
        <> pinToolsWithDatabase dispatchEnv.beSessions dispatchEnv.beDefaultModel dc
        <> taskToolsWithDatabase dc
        <> skillToolsFor dispatchEnv.beSkills dc prepareSkill bindPackages
        <> skillAuthoringToolsWithDatabase dispatchEnv.beSkills dc authoringCatalog
        <> bilibiliToolsFor dispatchEnv.beTimeZone dc
        <> sandboxToolsFor dispatchEnv.beTimeZone (toolGroupId dc) dispatchEnv.beSandboxes
        <> fileToolsWithDatabase dispatchEnv.beTimeZone dc dispatchEnv.beSandboxes
        <> [t | toolStickers dc && dispatchEnv.beEmbeddingEnabled, t <- stickerToolsWithDatabase]
        <> maybe [] (searchToolsFor runtime) dispatchEnv.beSearch
        <> maxOpsBundle
          runtime
          dispatchEnv.beMaxOps
          ((.rsValues.rvMaxOps) <$> currentRuntimeSnapshot env.beConfigStore)
          (toolGroupId dc)
          (map fst remotePairs)
          (admitMaxOpsTask dc dispatchEnv.beMaxOps)
        <> [t | toolMultimodal dc, t <- browserToolsFor dc dispatchEnv.beBrowsers dispatchEnv.beBrowserProxy]
        <> [t | toolMultimodal dc, t <- videoToolsWithDatabase dc]

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
  length (filter (toolVisible Map.empty . (.tdRef.unToolRef)) (toolDefinitionsFor env gid (TurnCapabilities multimodal stickers skills noAdvertisedCaps True Map.empty Nothing False)))

-- | Product-level visibility and effect metadata live in one inventory.  The
-- actual runners assembled above must match this filtered set exactly or
-- 'buildToolRegistry' rejects the dispatch before the model sees a schema.
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
      MaxOpsOnly -> maxOpsAllowed env.beMaxOps gid
      MonitorArmOnly -> caps.tcMonitorArming
      BackgroundOnly -> caps.tcBackground
      FrontendOnly -> not caps.tcBackground && isNothing caps.tcEffectCeiling
    ceilingOpen definition' =
      (caps.tcBackground && definition'.tdRef `elem` [ToolRef "task_finish", ToolRef "task_progress"])
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
  | MaxOpsOnly
  | MonitorArmOnly
  | FrontendOnly
  | BackgroundOnly

data ToolInventoryItem = ToolInventoryItem
  { tiGate :: !ToolGate,
    tiDefinition :: !ToolDefinition
  }

-- | Metadata only, shared by isolated skill acceptance and the serving catalog.
-- Runners and the current caller's authorization remain separate.
skillToolDefinitions :: [ToolDefinition]
skillToolDefinitions = [item.tiDefinition | item <- toolInventory, item.tiDefinition.tdRef.unToolRef `elem` ["use_skill", "skill_save", "skill_inspect", "skill_validate", "skill_publish"]]

toolInventory :: [ToolInventoryItem]
toolInventory =
  [ always (readTool "inspect_source" ["self.source"] [ProcessResource "self-source"]),
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
    always (writeToolV 2 "configure_monitor" ["monitor.db"] [CurrentConversation]),
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
    gated SkillsOnly (failsBeforeEffects (writeTool "skill_save" ["skill.drafts"] [CurrentConversation])),
    gated SkillsOnly (readTool "skill_inspect" ["skill.drafts", "skill.publications"] [CurrentConversation]),
    gated SkillsOnly (withDeadline 120 (failsBeforeEffects (writeTool "skill_validate" ["skill.validations"] [CurrentConversation]))),
    gated SkillsOnly (failsBeforeEffects (writeTool "skill_publish" ["skill.publications"] [CurrentConversation])),
    always (writeTool "task_start" ["task.db"] [CurrentConversation]),
    always (readTool "task_list" ["task.db"] [CurrentConversation]),
    always (readTool "task_status" ["task.db"] [CurrentConversation]),
    always (writeTool "task_steer" ["task.db"] [CurrentConversation]),
    always (writeTool "task_replace" ["task.db"] [CurrentConversation]),
    always (writeTool "task_cancel" ["task.db"] [CurrentConversation]),
    gated BackgroundOnly ((writeToolV 2 "task_finish" ["task.db"] [CurrentConversation]) {tdCallMode = FinishCall}),
    gated BackgroundOnly ((writeTool "task_progress" ["task.db"] [CurrentConversation]) {tdCallMode = CheckpointCall}),
    -- Returned request validation/ownership errors precede every write in
    -- submitRequestWithInputs. Exceptions and timeouts remain outcome-unknown.
    gated FrontendOnly ((failsBeforeEffects (writeToolV 2 "request_finish" ["task.db"] [CurrentConversation])) {tdCallMode = FinishCall}),
    -- Queues turn-scoped inline video as well as reading the network.  Keep it
    -- sequential inside one agent round so concurrent calls cannot race the
    -- shared attachment order/budget; independent turns have independent
    -- ToolOutput interpreters and still run concurrently.
    always (statefulReadTool "view_bilibili" ["network.bilibili", "tool.media"] [CurrentConversation]),
    always (writeTool "sandbox_create" ["sandbox.lifecycle"] [CurrentConversation, ProcessResource "sandbox"]),
    -- The model picks this one's timeout itself, clamped to ten minutes, and
    -- 'timeout --preserve-status' enforces it inside the container.  What that
    -- cannot bound is the host side: a wedged runtime client leaves the call
    -- hanging with the command already finished or never started.  So this is
    -- the container's own ceiling plus enough slack to be sure the difference
    -- is the runtime's and not the command's. It sits above the turn watchdog on
    -- purpose — for a front-model turn that watchdog fires first, and this is
    -- here for the plan executor, which has no such thing over it.
    always (withDeadline 660 (writeTool "sandbox_exec" ["sandbox.process", "sandbox.fs"] [CurrentConversation, ProcessResource "sandbox"])),
    -- Host package search has its own 120s bound; allow transport slack here.
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
    gated MaxOpsOnly (readTool "maxops_operations" ["fleet.observations"] [CurrentConversation, ProcessResource "maxops"]),
    gated MaxOpsOnly (readTool "maxops_query" ["fleet.observations"] [CurrentConversation, ProcessResource "maxops"]),
    gated MaxOpsOnly (writeTool "maxops_execute" ["fleet.management", "task.db"] [CurrentConversation, ProcessResource "maxops"]),
    gated MultimodalOnly (browserTool "browser"),
    gated MultimodalOnly (browserTool "view_zhihu"),
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
      tdFailuresPrecedeEffects = False,
      tdCallMode = WorkCall
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
