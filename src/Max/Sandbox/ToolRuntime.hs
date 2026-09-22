module Max.Sandbox.ToolRuntime (sandboxToolsWithRuntime) where

import Effectful (IOE, type (:>))
import Max.Effects.Sandbox (runSandbox)
import Max.Effects.Tools (Tool, hoistTool)
import Max.Sandbox.Registry (SandboxRegistry)
import Max.Tools.Sandbox (sandboxTools)
import OneBot.Types (GroupId)

sandboxToolsWithRuntime :: (IOE :> es) => GroupId -> SandboxRegistry -> [Tool es]
sandboxToolsWithRuntime group registry = map (hoistTool (runSandbox group registry)) sandboxTools
