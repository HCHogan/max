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
  )
where

import Data.Set qualified as Set
import Data.Text (Text)
import Effectful
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
    ToolAuthority (..),
    ToolCatalog,
    ToolCatalogError,
    ToolDefinition (..),
    ToolEffect (..),
    ToolParallelism (..),
    ToolRef (..),
    ToolRetryClass (..),
    buildToolCatalog,
  )
import Max.Env (BotEnv (..))
import Max.HttpRuntime (HttpRuntime)
import Max.ToolContext (ToolContext, TurnCapabilities (..), toolCapabilities, toolGroupId, toolMultimodal, toolStickers)
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
  buildToolCatalog (toolDefinitionsFor env (toolGroupId dc) (toolCapabilities dc)) runners
  where
    runners =
      builtinsFor env.beTimeZone dc
        <> reminderToolsFor env.beTimeZone env.beReminders dc
        <> groupToolsFor dc
        <> imageToolsFor env.beTimeZone dc
        <> memoryToolsFor dc
        <> pinToolsFor env.beSessions env.beDefaultModel dc
        <> skillToolsFor env.beSkills dc
        <> bilibiliToolsFor env.beTimeZone dc
        <> sandboxToolsFor env.beTimeZone (toolGroupId dc) env.beSandboxes
        <> fileToolsFor env.beTimeZone dc env.beSandboxes
        <> [t | toolStickers dc && env.beEmbeddingEnabled, t <- stickerToolsFor]
        <> maybe [] (searchToolsFor runtime) env.beSearch
        <> [t | toolMultimodal dc, t <- browserToolsFor (toolGroupId dc) env.beBrowsers]
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
  length (toolDefinitionsFor env gid (TurnCapabilities multimodal stickers skills))

-- | Product-level visibility and effect metadata live in one inventory.  The
-- actual runners assembled above must match this filtered set exactly or
-- 'buildToolCatalog' rejects the dispatch before the model sees a schema.
toolDefinitionsFor :: BotEnv -> GroupId -> TurnCapabilities -> [ToolDefinition]
toolDefinitionsFor env gid caps =
  [ item.tiDefinition
  | item <- toolInventory,
    gateOpen item.tiGate
  ]
  where
    gateOpen = \case
      Always -> True
      GroupOnly -> not (isPrivateChat gid)
      MultimodalOnly -> caps.tcMultimodal
      StickersOnly -> caps.tcStickers && env.beEmbeddingEnabled
      SkillsOnly -> caps.tcSkills
      SearchOnly -> maybe False (const True) env.beSearch

data ToolGate
  = Always
  | GroupOnly
  | MultimodalOnly
  | StickersOnly
  | SkillsOnly
  | SearchOnly

data ToolInventoryItem = ToolInventoryItem
  { tiGate :: !ToolGate,
    tiDefinition :: !ToolDefinition
  }

toolInventory :: [ToolInventoryItem]
toolInventory =
  [ always (readTool "inspect_source" ["self.source"] [ProcessResource "self-source"]),
    always (readTool "get_message_by_id" ["conversation.db"] [CurrentConversation]),
    always (llmReadTool "context_search" ["conversation.db"] [CurrentConversation]),
    always (readTool "context_expand" ["conversation.db"] [CurrentConversation]),
    always (readTool "view_forward" ["conversation.db"] [CurrentConversation]),
    always (sendTool "poke" "chat.endpoint"),
    always (writeTool "set_reminder" ["reminder.db"] [CurrentConversation]),
    always (readTool "list_reminders" ["reminder.db"] [CurrentConversation]),
    always (writeTool "cancel_reminder" ["reminder.db"] [CurrentConversation]),
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
    always (readTool "view_bilibili" ["network.bilibili"] [CurrentConversation]),
    always (writeTool "sandbox_create" ["sandbox.lifecycle"] [CurrentConversation, ProcessResource "sandbox"]),
    always (writeTool "sandbox_exec" ["sandbox.process", "sandbox.fs"] [CurrentConversation, ProcessResource "sandbox"]),
    always (statefulReadTool "nix_search" ["sandbox.process", "network.nix"] [CurrentConversation, ProcessResource "sandbox"]),
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
      tdAuthorities = Set.fromList authorities
    }

readTool :: Text -> [Text] -> [ToolAuthority] -> ToolDefinition
readTool name domains =
  definition name (map EffectRead domains) ParallelSafe RetrySafe

statefulReadTool :: Text -> [Text] -> [ToolAuthority] -> ToolDefinition
statefulReadTool name domains =
  definition name (map EffectRead domains) SequentialOnly RetrySafe

writeTool :: Text -> [Text] -> [ToolAuthority] -> ToolDefinition
writeTool name domains =
  definition name (map EffectWrite domains) SequentialOnly RetryUnsafe

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

browserTool :: Text -> ToolDefinition
browserTool name =
  definition
    name
    [EffectWrite "browser.session", EffectRead "network.web"]
    SequentialOnly
    RetryUnsafe
    [CurrentConversation, ProcessResource "browser"]
