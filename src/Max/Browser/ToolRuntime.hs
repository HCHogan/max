-- | Workspace ownership is established before native browser tools run.
module Max.Browser.ToolRuntime (browserToolsFor, browserToolsAt) where

import Data.Text (Text)
import Effectful
import Effectful.PostgreSQL (WithConnection)
import Max.Browser.Client (runBrowserWithRegistry)
import Max.Browser.Registry
  ( BrowserRegistry,
    BrowserScope,
    browserScopeIsTask,
  )
import Max.Browser.Runtime (managedBrowserTools)
import Max.Effects.ToolOutput (ToolOutput)
import Max.Effects.Tools (Tool, hoistTool)
import Max.Jobs (Jobs)
import Max.ToolContext (ToolContext)
import Max.Tools.Browser qualified as Protocol (browserToolsAt)

browserToolsFor :: (WithConnection :> es, IOE :> es, ToolOutput :> es) => Jobs -> ToolContext -> BrowserRegistry -> Maybe Text -> [Tool es]
browserToolsFor jobs context reg proxy = managedBrowserTools jobs context reg (\scope -> browserToolsAt scope reg proxy)

browserToolsAt :: (IOE :> es, ToolOutput :> es) => BrowserScope -> BrowserRegistry -> Maybe Text -> [Tool es]
browserToolsAt scope registry proxy = map (hoistTool (runBrowserWithRegistry scope registry proxy)) (Protocol.browserToolsAt (browserScopeIsTask scope))
