#!/usr/bin/env python3
"""Check domain imports and capability denial using the actual compiled library.

Run after cabal build all. Pure roots are a closed import set: adding an effect,
store or assembly dependency (also through a helper) requires moving that code
out of the pure layer. Negative fixtures are paired with a compiling positive
fixture, so a broken compiler/package setup cannot masquerade as enforcement.
"""

import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PURE = {
    "Max.AgentEvent",
    "Max.LLM.Types",
    "Max.LLM.Failure",
    "Max.Http.Failure",
    "Max.Agent.Failure",
    "Max.LLM.Protocol",
    "Max.LLM.Stream",
    "Max.ModelCatalog.Internal",
    "Max.Tool.Types",
    "Max.Tool.Control",
    "Max.Tool.Catalog",
    "Max.Task.Types",
    "Max.Task.State",
    "Max.Task.Execution",
    "Max.Task.Query",
    "Max.Task.Overview",
    "Max.Task.Admission",
    "Max.Task.View",
    "Max.Browser.State",
    "Max.Platform.Failure",
    "Max.Monitor.Policy",
    "Max.Monitor.Control",
    "Max.Memory.Policy",
    "Max.Pin.Policy",
    "Max.Blob.Reference",
    "Max.Time.Parse",
}
IMPORT = re.compile(r"^import\s+(?:qualified\s+)?([A-Z][\w.]*)", re.MULTILINE)


def check_imports():
    errors = []
    for module in sorted(PURE):
        path = ROOT / "src" / (module.replace(".", "/") + ".hs")
        source = path.read_text()
        for dependency in IMPORT.findall(source):
            pure_external = dependency.startswith(("Data.", "Crypto.Hash.")) or dependency in {"Text.Read", "Control.Applicative", "Network.HTTP.Types.Header"}
            # Exception is a typeclass declaration; no exception-throwing IO.
            exception_type = dependency == "Control.Exception" and "import Control.Exception (Exception)" in source
            if dependency not in PURE and not pure_external and not exception_type:
                errors.append(f"{module}: impure or unreviewed dependency {dependency}")
        if re.search(r"\b(IOE|liftIO|unsafePerformIO|unsafeCoerce)\b", source):
            errors.append(f"{module}: implementation escape in pure domain module")

    # Read-model codecs may decode SQL fields, but cannot execute queries or IO.
    read_models = {
        "Max.Memory.Types": {"Max.ConversationScope", "Max.Memory.Policy"},
        "Max.History.Types": {"Control.Applicative", "Max.IR"},
        "Max.Media.Types": set(),
        "Max.File.Types": {"Max.Blob.Reference"},
        "Max.Conversation.Roster": {"GHC.Generics", "Max.Platform.Types"},
        "Max.Episode.Types": {"Max.History.Types"},
        "Max.Recall.Types": {"Max.Episode.Types", "Max.Memory.Types"},
        "Max.Context.Media": {"Max.History.Types", "Max.Media.Types", "Max.Time"},
    }
    codecs = {"Database.PostgreSQL.Simple.FromField", "Database.PostgreSQL.Simple.ToField", "Database.PostgreSQL.Simple.FromRow"}
    for module, allowed in read_models.items():
        source = (ROOT / "src" / (module.replace(".", "/") + ".hs")).read_text()
        for dependency in IMPORT.findall(source):
            if not dependency.startswith("Data.") and dependency not in allowed | codecs:
                errors.append(f"{module}: executable dependency {dependency}")
        if re.search(r"\b(IOE|liftIO|unsafePerformIO|unsafeCoerce)\b", source):
            errors.append(f"{module}: execution escape")

    source = (ROOT / "src/Max/Effects/ToolDirectory.hs").read_text()
    allowed = {"Effectful", "Effectful.Dispatch.Dynamic", "Max.Tool.Catalog", "Max.Tool.Types"}
    for dependency in IMPORT.findall(source):
        if dependency not in allowed:
            errors.append(f"ToolDirectory: execution dependency {dependency}")
    if re.search(r"\b(IOE|liftIO|ToolRegistry|invokeTool)\b", source):
        errors.append("ToolDirectory: execution capability in read-only directory")

    embedding = (ROOT / "src/Max/Effects/Embedding.hs").read_text()
    if set(IMPORT.findall(embedding)) & {"Max.Env", "Max.RuntimeConfig", "Effectful.Reader.Dynamic"}:
        errors.append("Embedding: application environment leaked into the client contract")

    agent = (ROOT / "src/Max/Effects/Agent.hs").read_text()
    for dependency in IMPORT.findall(agent):
        if dependency.startswith("Max.DB.") or dependency in {"Effectful.PostgreSQL", "Max.Agent.Runtime", "Max.Effects.Blob"}:
            errors.append(f"Agent: persistence or assembly dependency {dependency}")

    raw_edges = {
        "src/OneBot/Server.hs", "src/Max/Platform.hs",
        "src/Max/Platform/Rpc.hs", "src/Max/Platform/Runtime.hs",
        "src/Max/Platform/QQHistory.hs", "src/Max/Platform/Delivery.hs",
        "src/Max/WechatHook.hs", "src/Max/Effects/PlatformQuery.hs",
        "src/Max/Effects/PlatformInteraction.hs", "src/Max/Effects/PlatformAccount.hs",
    }
    read_only_platform = {"src/Max/Roster.hs", "src/Max/Tools/Group.hs", "src/Max/Files.hs", "src/Max/Forward.hs"}
    for path in (ROOT / "src").rglob("*.hs"):
        relative = path.relative_to(ROOT).as_posix()
        source = path.read_text()
        dependencies = set(IMPORT.findall(source))
        if relative != "src/Max/MemoryStore.hs" and re.search(r"\bcreateMemory\b", source):
            errors.append(f"{relative}: memory creation bypasses shared admission")
        domain_tools = {"src/Max/Tools/Task.hs", "src/Max/Tools/Monitor.hs", "src/Max/Tools/Reminder.hs", "src/Max/Tools/Memory.hs", "src/Max/Tools.hs", "src/Max/Tools/Pins.hs", "src/Max/Tools/Group.hs", "src/Max/Tools/Images.hs", "src/Max/Tools/Video.hs", "src/Max/Tools/Stickers.hs"}
        resource_tools = {"src/Max/Tools/Files.hs", "src/Max/Tools/Browser.hs"}
        if relative in domain_tools | resource_tools:
            if any(dependency.startswith("Max.DB.") for dependency in dependencies) or dependencies & {"Effectful.PostgreSQL", "Max.Platform.Store", "Max.Session", "Max.Reply.Resolve", "Max.Reply.Caption", "Max.Task.ToolRuntime", "Max.Monitor.ToolRuntime", "Max.Memory.ToolRuntime", "Max.MemoryStore", "Max.EpisodeStore", "Max.Recall", "Max.Prompt", "Max.Conversation.ToolRuntime", "Max.Monitor", "Max.Tools"}:
                errors.append(f"{relative}: raw storage/assembly dependency")
            if relative not in {"src/Max/Tools/Images.hs", "src/Max/Tools/Video.hs", "src/Max/Tools/Files.hs"} and "Max.Effects.Blob" in dependencies:
                errors.append(f"{relative}: unneeded content store capability")
            if any(dependency.endswith(".ToolRuntime") or dependency == "Max.Browser.Runtime" for dependency in dependencies):
                errors.append(f"{relative}: host assembly dependency")
            if relative in domain_tools and re.search(r"\b(IOE|WithConnection|liftIO)\b", source):
                errors.append(f"{relative}: unrestricted IO/database capability")
        if dependencies & {"OneBot.Action", "Max.Platform.Rpc"} and relative not in raw_edges:
            errors.append(f"{relative}: raw platform RPC outside an adapter/interpreter")
        if "Max.Effects.PlatformApi" in dependencies:
            errors.append(f"{relative}: retired broad platform effect")
        if relative in read_only_platform and dependencies & {"Max.Effects.PlatformInteraction", "Max.Effects.PlatformAccount"}:
            errors.append(f"{relative}: platform writes in a read-only consumer")
        if "Max.Effects.ToolControl" in dependencies and relative not in {
            "src/Max/Tools/Task.hs", "src/Max/Task/ToolRuntime.hs", "src/Max/Toolset.hs", "src/Max/Agent/Runtime.hs", "src/Max/Effects/Agent.hs"
        }:
            errors.append(f"{relative}: host loop control outside trusted task runners/assembly")
        if relative.startswith("src/Max/Tools") and "Max.Effects.PlatformAccount" in dependencies:
            errors.append(f"{relative}: account administration exposed to tools")
        if "Max.Effects.BlobHost" in IMPORT.findall(source) and relative not in {
            "src/Max/MediaCaption.hs", "src/Max/Tools/Files.hs", "src/Max/Toolset.hs", "src/Max/File/ToolRuntime.hs"
        }:
            errors.append(f"{relative}: host paths outside approved ffmpeg/docker adapters and assembly")
        if relative.startswith("src/Max/Tools/") and re.search(r"\b(ToolOutputRead|drainInlineMedia|runToolOutputRead|newToolOutputQueue)\b", source):
            errors.append(f"{relative}: tool acquired media consumer or queue assembly capability")
    if errors:
        raise RuntimeError("\n".join(errors))


HEADER = """{-# LANGUAGE DataKinds, FlexibleContexts, TypeOperators, OverloadedStrings, ImportQualifiedPost #-}
module CapabilityCheck where
import Data.Aeson (Value (Null), Result, fromJSON)
import Effectful
import Max.Effects.Blob
import Max.Effects.BlobHost
import Max.Effects.ToolControl
import Max.Tool.Control
import Max.Effects.ToolDirectory
import Max.Effects.ToolOutput
import Max.Effects.Tools
import Max.Effects.MediaQuery (MediaQuery, readImages)
import Max.Effects.StickerQuery (StickerQuery)
import Max.Effects.PinControl (PinControl, pinMessage)
import Max.Effects.ConversationQuery (ConversationQuery, readMessage)
import Max.Effects.MemoryQuery (MemoryQuery)
import Max.Effects.MemoryQuery qualified as MemoryQuery
import Max.Effects.MemoryControl (MemoryControl, saveMemory)
import Max.Memory.Policy (MemorySubject (ConversationMemory))
import Max.Effects.MonitorQuery (MonitorQuery, listMonitors)
import Max.Effects.MonitorControl (MonitorControl, controlMonitor)
import Max.Monitor.Control (MonitorCommand (CancelMonitor))
import Max.Monitor.Types (MonitorOrdinal (..))
import Max.Effects.TaskQuery (TaskQuery)
import Max.Effects.TaskQuery qualified as TaskQuery
import Max.Effects.TaskControl (TaskControl, startTask)
import Max.Effects.TaskExecution (TaskExecution, reportProgress)
import Max.Effects.TurnQuery (TurnQuery, resolveTurnResult)
import Max.Task.Types (TaskProfile (Research))
import Max.Effects.PlatformQuery
import Max.Effects.PlatformInteraction
import Max.Effects.PlatformAccount
import Max.Effects.Outbound (Outbound, OutboundRequest, sendRecorded)
import Max.Platform.Failure
import Max.Platform.Roster
import OneBot.Types (GroupId (..), UserId (..))
"""

POSITIVE = """
conversation :: ConversationQuery :> es => Eff es ()
conversation = () <$ readMessage 1
memories :: MemoryQuery :> es => Eff es ()
memories = () <$ MemoryQuery.listMemories ConversationMemory
editMemory :: MemoryControl :> es => Eff es ()
editMemory = () <$ saveMemory ConversationMemory "fact"
monitors :: MonitorQuery :> es => Eff es ()
monitors = () <$ listMonitors
changeMonitor :: MonitorControl :> es => Eff es ()
changeMonitor = () <$ controlMonitor (MonitorOrdinal 1) CancelMonitor False
content :: Blob :> es => BlobRef -> Eff es ()
content ref = () <$ readBlob ref
host :: BlobHost :> es => BlobRef -> Eff es FilePath
host = resolveBlobHostPath
produce :: ToolOutput :> es => InlineMedia -> Eff es Bool
produce = queueInlineMedia
consume :: ToolOutputRead :> es => Eff es [InlineMedia]
consume = drainInlineMedia
directory :: ToolDirectory :> es => Eff es [CatalogTool]
directory = listCatalogTools
execute :: Tools :> es => Eff es ToolOutcome
execute = invokeTool "read" Null
control :: ToolControl :> es => Eff es ()
control = finishExecution Nothing
readMedia :: MediaQuery :> es => Eff es ()
readMedia = () <$ readImages 1 Nothing
editPins :: PinControl :> es => Eff es ()
editPins = () <$ pinMessage 1
readTasks :: TaskQuery :> es => Eff es ()
readTasks = () <$ TaskQuery.listTasks
startOwnedTask :: TaskControl :> es => Eff es ()
startOwnedTask = () <$ startTask "key" "goal" Research Null
reportOwnedTask :: TaskExecution :> es => Eff es ()
reportOwnedTask = () <$ reportProgress "progress"
readOwnedResult :: TurnQuery :> es => Eff es ()
readOwnedResult = () <$ resolveTurnResult "t#1:r1"
query :: PlatformQuery :> es => Eff es (Either PlatformFailure GroupMeta)
query = queryGroupMeta (GroupId 1)
poke :: PlatformInteraction :> es => Eff es (Either PlatformFailure ())
poke = pokeUser (GroupId 1) (UserId 2)
account :: PlatformAccount :> es => Eff es (Either PlatformFailure ())
account = respondToFriendRequest "flag" AcceptFriend
publish :: Outbound :> es => OutboundRequest -> Eff es ()
publish request = () <$ sendRecorded request
"""

NEGATIVE = {
    "conversation query cannot control tasks": ("TaskControl", 'bad :: ConversationQuery :> es => Eff es ()\nbad = () <$ startTask "key" "goal" Research Null'),
    "conversation query cannot publish": ("Outbound", 'bad :: ConversationQuery :> es => OutboundRequest -> Eff es ()\nbad request = () <$ sendRecorded request'),
    "media query cannot publish": ("Outbound", "bad :: MediaQuery :> es => OutboundRequest -> Eff es ()\nbad request = () <$ sendRecorded request"),
    "media query cannot resolve host paths": ("BlobHost", "bad :: MediaQuery :> es => BlobRef -> Eff es FilePath\nbad = resolveBlobHostPath"),
    "media query cannot use arbitrary IO": ("IOE", 'bad :: MediaQuery :> es => Eff es ()\nbad = liftIO (pure ())'),
    "sticker query cannot publish": ("Outbound", "bad :: StickerQuery :> es => OutboundRequest -> Eff es ()\nbad request = () <$ sendRecorded request"),
    "conversation query cannot edit pins": ("PinControl", 'bad :: ConversationQuery :> es => Eff es ()\nbad = () <$ pinMessage 1'),
    "pin control cannot use arbitrary IO": ("IOE", 'bad :: PinControl :> es => Eff es ()\nbad = liftIO (pure ())'),
    "conversation query cannot use arbitrary IO": ("IOE", 'bad :: ConversationQuery :> es => Eff es ()\nbad = liftIO (pure ())'),
    "memory query cannot save": ("MemoryControl", 'bad :: MemoryQuery :> es => Eff es ()\nbad = () <$ saveMemory ConversationMemory "fact"'),
    "memory query cannot use arbitrary IO": ("IOE", 'bad :: MemoryQuery :> es => Eff es ()\nbad = liftIO (pure ())'),
    "memory control cannot query other subjects": ("MemoryQuery", 'bad :: MemoryControl :> es => Eff es ()\nbad = () <$ MemoryQuery.listMemories ConversationMemory'),
    "monitor query cannot control a monitor": ("MonitorControl", 'bad :: MonitorQuery :> es => Eff es ()\nbad = () <$ controlMonitor (MonitorOrdinal 1) CancelMonitor False'),
    "monitor query cannot use arbitrary IO": ("IOE", 'bad :: MonitorQuery :> es => Eff es ()\nbad = liftIO (pure ())'),
    "monitor control cannot read other conversations": ("MonitorQuery", 'bad :: MonitorControl :> es => Eff es ()\nbad = () <$ listMonitors'),
    "task query cannot control tasks": ("TaskControl", 'bad :: TaskQuery :> es => Eff es ()\nbad = () <$ startTask "key" "goal" Research Null'),
    "task query cannot submit execution reports": ("TaskExecution", 'bad :: TaskQuery :> es => Eff es ()\nbad = () <$ reportProgress "done"'),
    "task query cannot use arbitrary IO": ("IOE", 'bad :: TaskQuery :> es => Eff es ()\nbad = liftIO (pure ())'),
    "turn result reader cannot control tasks": ("TaskControl", 'bad :: TurnQuery :> es => Eff es ()\nbad = () <$ startTask "key" "goal" Research Null'),
    "directory cannot stop an agent loop": ("ToolControl", 'bad :: ToolDirectory :> es => Eff es ()\nbad = finishExecution Nothing'),
    "loop control cannot be decoded from JSON": ("LoopControl", 'bad :: Value -> Result LoopControl\nbad = fromJSON'),
    "platform query cannot poke": ("PlatformInteraction", "bad :: PlatformQuery :> es => Eff es (Either PlatformFailure ())\nbad = pokeUser (GroupId 1) (UserId 2)"),
    "platform query cannot administer an account": ("PlatformAccount", 'bad :: PlatformQuery :> es => Eff es (Either PlatformFailure ())\nbad = respondToFriendRequest "flag" AcceptFriend'),
    "platform query cannot publish content": ("Outbound", "bad :: PlatformQuery :> es => OutboundRequest -> Eff es ()\nbad request = () <$ sendRecorded request"),
    "platform interaction cannot administer an account": ("PlatformAccount", 'bad :: PlatformInteraction :> es => Eff es (Either PlatformFailure ())\nbad = respondToFriendRequest "flag" AcceptFriend'),
    "platform account cannot query a roster": ("PlatformQuery", "bad :: PlatformAccount :> es => Eff es (Either PlatformFailure GroupMeta)\nbad = queryGroupMeta (GroupId 1)"),
    "content cannot resolve host paths": ("BlobHost", "bad :: Blob :> es => BlobRef -> Eff es FilePath\nbad = resolveBlobHostPath"),
    "producer cannot drain": ("ToolOutputRead", "bad :: ToolOutput :> es => Eff es [InlineMedia]\nbad = drainInlineMedia"),
    "consumer cannot produce": ("ToolOutput", "bad :: ToolOutputRead :> es => InlineMedia -> Eff es Bool\nbad = queueInlineMedia"),
    "directory cannot execute": ("Tools", 'bad :: ToolDirectory :> es => Eff es ToolOutcome\nbad = invokeTool "read" Null'),
    "directory cannot run arbitrary IO": ("IOE", "bad :: ToolDirectory :> es => Eff es ()\nbad = liftIO (pure ())"),
}


def check_capabilities():
    with tempfile.TemporaryDirectory(prefix="max-capabilities-") as directory:
        path = Path(directory) / "CapabilityCheck.hs"
        command = ["cabal", "exec", "--", "ghc", "-v0", "-fno-code", "-fforce-recomp", "-fdiagnostics-color=never", "-package", "max", str(path)]

        def compile_source(source):
            path.write_text(HEADER + source)
            return subprocess.run(command, cwd=ROOT, text=True, capture_output=True, timeout=60)

        positive = compile_source(POSITIVE)
        if positive.returncode:
            raise RuntimeError("Positive capability fixture failed:\n" + positive.stdout + positive.stderr)
        for name, (capability, source) in NEGATIVE.items():
            result = compile_source(source)
            diagnostic = result.stdout + result.stderr
            if result.returncode == 0:
                raise RuntimeError(f"Capability leak: {name}")
            if capability not in diagnostic or not re.search(r"Could not deduce|No instance for", diagnostic):
                raise RuntimeError(f"Unexpected compiler failure for {name}:\n{diagnostic}")
            print(f"PASS: {name}")


def main():
    check_imports()
    print("PASS: pure domain imports and restricted consumers")
    check_capabilities()


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, subprocess.TimeoutExpired) as error:
        print(error, file=sys.stderr)
        sys.exit(1)
