-- | Bind sandbox publication and canonical caption resolution at host assembly.
module Max.File.ToolRuntime (fileToolsWithDatabase) where

import Effectful
import Effectful.Log (Log)
import Effectful.PostgreSQL (WithConnection)
import Max.Effects.Blob (Blob)
import Max.Effects.Outbound (Outbound)
import Max.Effects.Tools (Tool, hoistTool)
import Max.File.TransferRuntime (runFileTransferWithDatabase)
import Max.Sandbox.Registry (SandboxRegistry)
import Max.ToolContext (ToolContext)
import Max.Tools.Files (fileTools)

fileToolsWithDatabase :: (Blob :> es, Outbound :> es, Log :> es, WithConnection :> es, IOE :> es) => ToolContext -> SandboxRegistry -> [Tool es]
fileToolsWithDatabase context sandboxes =
  map (hoistTool (runFileTransferWithDatabase context sandboxes)) fileTools
