-- | Assemble the full tool catalog from BotEnv. Kept separate from Max.Tools
-- because feature modules already import it; assembly there would create a cycle.
module Max.Toolset
  ( allToolsFor,
    inventoryToolNames,
    toolCountFor,
    toolDefinitionsFor,
    toolAllowedByEffectCeiling,
    defaultToolDeadline,
  )
where

import Data.Aeson (object, (.=))
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
import Max.Conversation.ToolRuntime
  ( builtinsWithDatabase,
    groupToolsWithDatabase,
  )
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
import Max.Env (BotEnv (..))
import Max.File.ToolRuntime (fileToolsWithDatabase)
import Max.HttpRuntime (HttpRuntime)
import Max.Media.ToolRuntime
  ( imageToolsWithDatabase,
    stickerToolsWithDatabase,
    videoStreamAttachment,
    videoToolsWithDatabase,
  )
import Max.Memory.ToolRuntime (memoryToolsWithDatabase)
import Max.Monitor.ToolRuntime
  ( monitorToolsWithDatabase,
  )
import Max.Pin.ToolRuntime (pinToolsWithDatabase)
import Max.Platform.Types (noAdvertisedCaps)
import Max.Sandbox.Runtime (networkForGroup)
import Max.Sandbox.ToolRuntime (sandboxToolsWithRuntime)
import Max.Search.Runtime (searchToolsWithRuntime)
import Max.Skill.ToolRuntime (skillToolsWithRuntime)
import Max.Skill.Workflow (bindWorkflowContracts)
import Max.Task.ToolRuntime (taskTools)
import Max.Tool.Bundles (toolBundle, toolVisible)
import Max.Tool.Catalog (catalogTools)
import Max.Tool.Types (ToolCallMode (..))
import Max.ToolContext
  ( ToolContext,
    TurnCapabilities (..),
    toolCapabilities,
    toolGroupId,
    toolMultimodal,
    toolSkillLoads,
    toolStickers,
    withToolSkillLoads,
  )
import Max.Tools.Bilibili (bilibiliToolsFor)
import Max.Turn.Continuity (toolCatalogFingerprint)
import OneBot.Types (GroupId (..), isPrivateChat)

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
resolvedToolsFor runtime env dc = (definitions, filter allowedRunner runners0)
  where
    authorized = toolDefinitionsFor env (toolGroupId dc) (toolCapabilities dc)
    definitions = filter (\definition' -> toolVisible (toolSkillLoads dc) definition'.tdRef.unToolRef) authorized
    allowedRefs = Set.fromList [definition'.tdRef.unToolRef | definition' <- authorized]
    visibleRefs = Set.fromList [definition'.tdRef.unToolRef | definition' <- definitions]
    allowedRunner tool = tool.toolName `Set.member` visibleRefs
    prepareSkill "operations" = do
      selected <- networkForGroup (let GroupId raw = toolGroupId dc in fromIntegral raw)
      pure $ case selected of
        Right "maxops" | "sandbox_exec" `Set.member` allowedRefs -> Right Nothing
        _ -> Left "当前群未开启 SSH 运维网络"
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
    bindPackages loads = do
      registry <- either (Left . T.pack . show) Right (allToolsFor runtime env (withToolSkillLoads loads dc) :: Either ToolCatalogError (ToolRegistry es))
      bindWorkflowContracts javaScriptRuntimeVersion (catalogTools (registryCatalog registry)) loads
    runners0 =
      builtinsWithDatabase env.beTimeZone dc
        <> monitorToolsWithDatabase env.beJobs env.beTimeZone env.beWebhookBaseUrl dc
        <> groupToolsWithDatabase dc
        <> imageToolsWithDatabase env.beTimeZone env.beSandboxes dc
        <> memoryToolsWithDatabase dc
        <> pinToolsWithDatabase env.beSessions env.beDefaultModel dc
        <> taskTools env.beJobs dc
        <> skillToolsWithRuntime env.beSkills dc prepareSkill bindPackages
        <> bilibiliToolsFor env.beTimeZone dc (videoStreamAttachment dc)
        <> sandboxToolsWithRuntime (toolGroupId dc) env.beSandboxes
        <> fileToolsWithDatabase dc env.beSandboxes
        <> [t | toolStickers dc && env.beEmbeddingEnabled, t <- stickerToolsWithDatabase]
        <> maybe [] (searchToolsWithRuntime runtime) env.beSearch
        <> [t | toolMultimodal dc, t <- browserToolsFor env.beJobs dc env.beBrowsers env.beBrowserProxy]
        <> [t | toolMultimodal dc, t <- videoToolsWithDatabase env.beSandboxes dc]

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
  length
    ( filter
        (toolVisible Map.empty . (.tdRef.unToolRef))
        ( toolDefinitionsFor
            env
            gid
            ( TurnCapabilities
                { tcMultimodal = multimodal,
                  tcStickers = stickers,
                  tcSkills = skills,
                  tcOutput = noAdvertisedCaps,
                  tcMonitorArming = True,
                  tcCatalogGrants = Map.empty,
                  tcEffectCeiling = Nothing,
                  tcBackground = False
                }
            )
        )
    )

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
      -- Ordinary foreground turns list create_automation for every initiator
      -- so the tool block (a cached prompt prefix) does not change with who
      -- speaks. Background tasks do not create automations.
      MonitorArmOnly -> caps.tcMonitorArming || (not caps.tcBackground && isNothing caps.tcEffectCeiling)
      BackgroundOnly -> caps.tcBackground
    ceilingOpen definition' =
      (caps.tcBackground && definition'.tdRef `elem` [ToolRef "task_wait", ToolRef "task_progress"])
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

data ToolInventoryItem = ToolInventoryItem
  { tiGate :: !ToolGate,
    tiDefinition :: !ToolDefinition
  }

-- | Every tool name the inventory can expose, before any gate.
inventoryToolNames :: [Text]
inventoryToolNames = [item.tiDefinition.tdRef.unToolRef | item <- toolInventory]

toolInventory :: [ToolInventoryItem]
toolInventory =
  [ always (readTool "inspect_source" ["self.source"] [ProcessResource "self-source"]),
    always ((llmReadTool "context_search" ["conversation.db"] [CurrentConversation]) {tdSchemaVersion = SchemaVersion 2}),
    always (readTool "context_resume" ["conversation.db"] [CurrentConversation]),
    always (readTool "context_read" ["conversation.db"] [CurrentConversation]),
    always (sendTool "poke" "chat.endpoint"),
    -- A time automation is its creator's own delayed request, so every
    -- foreground initiator sees create_automation; MonitorControl still
    -- rejects message and webhook triggers below group admin. Rejections
    -- all return before anything is armed.
    gated MonitorArmOnly (legacyFailureFingerprint (writeTool "create_automation" ["monitor.db"] [CurrentConversation])),
    always (readTool "list_automations" ["monitor.db"] [CurrentConversation]),
    always (writeTool "cancel_automation" ["monitor.db"] [CurrentConversation]),
    always (writeTool "update_automation" ["monitor.db"] [CurrentConversation]),
    always (readTool "automation_history" ["monitor.db"] [CurrentConversation]),
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
    always (writeToolV 2 "task_start" ["task.db"] [CurrentConversation]),
    always (readTool "task_list" ["task.db"] [CurrentConversation]),
    always (readTool "task_status" ["task.db"] [CurrentConversation]),
    always (writeTool "task_steer" ["task.db"] [CurrentConversation]),
    always (writeToolV 2 "task_replace" ["task.db"] [CurrentConversation]),
    always (writeTool "task_cancel" ["task.db"] [CurrentConversation]),
    gated BackgroundOnly (withDeadline 21600 (readTool "task_wait" ["task.state"] [CurrentConversation])),
    gated BackgroundOnly ((writeTool "task_progress" ["task.db"] [CurrentConversation]) {tdCallMode = CheckpointCall}),
    -- Queues turn-scoped inline video as well as reading the network.  Keep it
    -- sequential inside one agent round so concurrent calls cannot race the
    -- shared attachment order/budget; independent turns have independent
    -- ToolOutput interpreters and still run concurrently.
    always (statefulReadTool "view_bilibili" ["network.bilibili", "tool.media"] [CurrentConversation]),
    -- Sandbox tools act on the group's sandbox, started on first use. These
    -- definitions keep their earlier fingerprints so standing grants still match.
    -- Allow the container's 600s command timeout plus 60s for the runtime client.
    always (withDeadline 660 ((writeTool "sandbox_exec" ["sandbox.process", "sandbox.fs"] [CurrentConversation, ProcessResource "sandbox"]) {tdParallelism = ParallelIndependent})),
    -- Host package search has its own 120s bound; allow transport slack here.
    always (withDeadline 180 (statefulReadTool "nix_search" ["sandbox.process", "network.nix"] [CurrentConversation, ProcessResource "sandbox"])),
    always (writeTool "sandbox_destroy" ["sandbox.lifecycle"] [CurrentConversation, ProcessResource "sandbox"]),
    -- Paths are sandbox paths: /work, and /chat mirroring this chat's files.
    always (statefulReadTool "read_file" ["sandbox.fs"] [CurrentConversation, ProcessResource "sandbox"]),
    always (writeTool "write_file" ["sandbox.fs"] [CurrentConversation, ProcessResource "sandbox"]),
    always (sendReadTool "send_image" ["sandbox.fs"]),
    always (sendReadTool "send_file" ["sandbox.fs"]),
    gated StickersOnly (llmReadTool "find_stickers" ["sticker.db"] [CurrentConversation]),
    gated SearchOnly (readTool "web_search" ["network.search"] [CurrentConversation]),
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

-- | Bound individual calls so a stalled tool returns before the turn watchdog.
-- Long-running tools override this deadline explicitly.
defaultToolDeadline :: ToolDeadline
defaultToolDeadline = ToolDeadline 120

-- | Override for the tools whose work is legitimately long.
withDeadline :: Int -> ToolDefinition -> ToolDefinition
withDeadline seconds definition' = definition' {tdDeadline = ToolDeadline seconds}

-- | Preserve historical catalog/grant hashes. Execution ignores this bit;
-- new runners report failure knowledge through ToolOutcome.
legacyFailureFingerprint :: ToolDefinition -> ToolDefinition
legacyFailureFingerprint definition' = definition' {tdFailuresPrecedeEffects = True}

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
