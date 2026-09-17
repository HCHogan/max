module Max.Sandbox.ToolRuntime (sandboxToolsWithRuntime) where

import Data.Time (TimeZone)
import Effectful (IOE, type (:>))
import Max.Effects.Sandbox (runSandbox)
import Max.Effects.Tools (Tool, hoistTool)
import Max.Sandbox.Registry (SandboxRegistry)
import Max.Tools.Sandbox (sandboxToolsFor)
import OneBot.Types (GroupId)

sandboxToolsWithRuntime :: (IOE :> es) => TimeZone -> GroupId -> SandboxRegistry -> [Tool es]
sandboxToolsWithRuntime tz group registry = map (hoistTool (runSandbox group registry)) (sandboxToolsFor tz)
