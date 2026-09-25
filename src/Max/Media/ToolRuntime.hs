-- | Assemble scoped media readers and the explicit ffmpeg preparation edge.
module Max.Media.ToolRuntime (imageToolsWithDatabase, videoToolsWithDatabase, videoStreamAttachment, stickerToolsWithDatabase) where

import Control.Exception (IOException)
import Data.ByteString (ByteString)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (TimeZone)
import Effectful
import Effectful.Exception (try)
import Effectful.Log (Log)
import Effectful.PostgreSQL (WithConnection)
import Max.Effects.Blob (Blob, blobRefFromSha256, readBlob)
import Max.Effects.Embedding (Embedding)
import Max.Effects.MediaQuery (runMediaQuery)
import Max.Effects.StickerQuery (runStickerQuery)
import Max.Effects.ToolOutput (ToolOutput)
import Max.Effects.Tools (Tool, hoistTool)
import Max.Hash (sha256Hex)
import Max.Media.Prepare (prepareImageWithin)
import Max.Media.Rendition (rawVideoAttachment, videoRendition)
import Max.Media.Types (StoredVideo (..))
import Max.Media.Vision (VideoAttachment, VideoWindow, wholeVideo)
import Max.ModelCatalog (ContextLimits (..))
import Max.ToolContext (ToolContext, toolContextLimits, toolConversationScope)
import Max.Tools.Images (imageToolsFor)
import Max.Tools.Stickers (stickerToolsFor)
import Max.Tools.Video (videoToolsFor)

imageToolsWithDatabase :: (Blob :> es, Log :> es, ToolOutput :> es, WithConnection :> es, IOE :> es) => TimeZone -> ToolContext -> [Tool es]
imageToolsWithDatabase tz context = map (hoistTool (runMediaQuery (toolConversationScope context))) (imageToolsFor tz context (\mime bytes -> liftIO (prepareImageWithin (toolContextLimits context).visionLimits mime bytes)))

videoToolsWithDatabase :: (Blob :> es, Log :> es, ToolOutput :> es, WithConnection :> es, IOE :> es) => ToolContext -> [Tool es]
videoToolsWithDatabase context = map (hoistTool (runMediaQuery (toolConversationScope context))) (videoToolsFor (\video window -> raise (storedVideoAttachment context video window)))

-- | A stored video as the current profile should receive it.
storedVideoAttachment :: (Blob :> es, Log :> es, WithConnection :> es, IOE :> es) => ToolContext -> StoredVideo -> VideoWindow -> Eff es (Either Text VideoAttachment)
storedVideoAttachment context video window = case blobRefFromSha256 video.storedVideoSha256 of
  Nothing -> pure (Left "视频存储引用无效")
  Just ref ->
    let load = either (Left . ("视频读取失败: " <>) . T.pack . show) Right <$> try @IOException (readBlob ref)
     in case (toolContextLimits context).visionLimits of
          Nothing -> fmap (rawVideoAttachment video.storedVideoMime video.storedVideoDurationSeconds) <$> load
          Just limits -> videoRendition limits window video.storedVideoSha256 load

-- | A fetched stream (e.g. a Bilibili video) as the current profile should
-- receive it; renditions are cached by the stream's content.
videoStreamAttachment :: (Blob :> es, Log :> es, WithConnection :> es, IOE :> es) => ToolContext -> ByteString -> Eff es (Either Text VideoAttachment)
videoStreamAttachment context bytes = case (toolContextLimits context).visionLimits of
  Nothing -> pure (Right (rawVideoAttachment "video/mp4" Nothing bytes))
  Just limits -> videoRendition limits wholeVideo (sha256Hex bytes) (pure (Right bytes))

stickerToolsWithDatabase :: (Embedding :> es, Log :> es, WithConnection :> es, IOE :> es) => [Tool es]
stickerToolsWithDatabase = map (hoistTool runStickerQuery) stickerToolsFor
