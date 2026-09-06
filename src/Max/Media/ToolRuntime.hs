-- | Assemble scoped media readers and the explicit ffmpeg preparation edge.
module Max.Media.ToolRuntime (imageToolsWithDatabase, videoToolsWithDatabase, stickerToolsWithDatabase) where

import Data.Time (TimeZone)
import Effectful
import Effectful.Log (Log)
import Effectful.PostgreSQL (WithConnection)
import Max.Effects.Blob (Blob)
import Max.Effects.Embedding (Embedding)
import Max.Effects.MediaQuery (runMediaQuery)
import Max.Effects.StickerQuery (runStickerQuery)
import Max.Effects.ToolOutput (ToolOutput)
import Max.Effects.Tools (Tool, hoistTool)
import Max.ImagePrep (prepareImageForLLM)
import Max.ToolContext (ToolContext, toolConversationScope)
import Max.Tools.Images (imageToolsFor)
import Max.Tools.Stickers (stickerToolsFor)
import Max.Tools.Video (videoToolsFor)

imageToolsWithDatabase :: (Blob :> es, Log :> es, ToolOutput :> es, WithConnection :> es, IOE :> es) => TimeZone -> ToolContext -> [Tool es]
imageToolsWithDatabase tz context = map (hoistTool (runMediaQuery (toolConversationScope context))) (imageToolsFor tz context (\mime bytes -> liftIO (prepareImageForLLM mime bytes)))

videoToolsWithDatabase :: (Blob :> es, Log :> es, ToolOutput :> es, WithConnection :> es, IOE :> es) => ToolContext -> [Tool es]
videoToolsWithDatabase context = map (hoistTool (runMediaQuery (toolConversationScope context))) videoToolsFor

stickerToolsWithDatabase :: (Embedding :> es, Log :> es, WithConnection :> es, IOE :> es) => [Tool es]
stickerToolsWithDatabase = map (hoistTool runStickerQuery) stickerToolsFor
