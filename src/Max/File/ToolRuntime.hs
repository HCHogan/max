-- | Bind catalog reads and canonical caption resolution at host assembly.
module Max.File.ToolRuntime (fileToolsWithDatabase) where

import Data.Time (TimeZone)
import Effectful
import Effectful.Log (Log)
import Effectful.PostgreSQL (WithConnection)
import Max.Effects.Blob (Blob)
import Max.Effects.BlobHost (BlobHost)
import Max.Effects.MediaQuery (runMediaQuery)
import Max.Effects.Outbound (Outbound)
import Max.Effects.Tools (Tool, hoistTool)
import Max.Reply.Caption (captionBody)
import Max.Sandbox.Registry (SandboxRegistry)
import Max.ToolContext (ToolContext, toolConversationScope, toolGroupId, toolOutputCapabilities)
import Max.Tools.Files (fileToolsFor)

fileToolsWithDatabase :: (BlobHost :> es, Blob :> es, Outbound :> es, Log :> es, WithConnection :> es, IOE :> es) => TimeZone -> ToolContext -> SandboxRegistry -> [Tool es]
fileToolsWithDatabase tz context sandboxes =
  map (hoistTool (runMediaQuery (toolConversationScope context))) $
    fileToolsFor tz context (captionBody (toolOutputCapabilities context) (toolGroupId context)) sandboxes
