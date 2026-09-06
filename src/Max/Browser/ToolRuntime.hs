-- | Workspace ownership is established before native browser tools run.
module Max.Browser.ToolRuntime (browserToolsFor) where

import Data.Text (Text)
import Effectful
import Effectful.PostgreSQL (WithConnection)
import Max.Browser.Registry (BrowserRegistry)
import Max.Browser.Runtime (managedBrowserTools)
import Max.Effects.Tools (Tool)
import Max.ToolContext (ToolContext)
import Max.Tools.Browser (browserToolsAt)

browserToolsFor :: (WithConnection :> es, IOE :> es) => ToolContext -> BrowserRegistry -> Maybe Text -> [Tool es]
browserToolsFor context reg proxy = managedBrowserTools context reg (\scope -> browserToolsAt scope reg proxy)
