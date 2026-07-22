-- |
-- @view_video@: let a video-capable multimodal profile watch a group
-- video.  Videos are downloaded at receive time by the media worker
-- (same pool as images) into the content-addressed blob store; this
-- tool reads the local copy and attaches it whole, as an inline
-- @data:video\/...@ block — models with native video input (Kimi K3,
-- Qwen-VL, …) take it directly.
module Max.Tools.Video
  ( videoToolsFor,
  )
where

import Control.Exception (IOException, try)
import Data.Aeson
import Data.Aeson.Types (parseEither)
import Data.ByteString qualified as BS
import Data.ByteString.Base64 qualified as B64
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Effectful
import Effectful.Log
import Effectful.PostgreSQL (WithConnection, query)
import Database.PostgreSQL.Simple (Only (..))
import Max.Effects.Agent (DispatchContext (..), ToolImage (..), queueToolImage)
import Max.Effects.Tools (Tool (..))
import System.FilePath ((</>))

videoToolsFor ::
  (WithConnection :> es, Log :> es, IOE :> es) =>
  FilePath -> -- blob store root
  DispatchContext ->
  [Tool es]
videoToolsFor blobRoot dc = [viewVideoTool blobRoot dc]

viewVideoTool ::
  (WithConnection :> es, Log :> es, IOE :> es) =>
  FilePath ->
  DispatchContext ->
  Tool es
viewVideoTool blobRoot dc =
  Tool
    { toolName = "view_video",
      toolDescription =
        T.unwords
          [ "看一条群里发的视频：传 [video#<id>] 里的 <id>，整段视频会附在",
            "下一条消息里给你看（占用本次任务 8 个附件配额中的 1 个）。",
            "同一个视频看一次就够了。"
          ],
      toolSchema =
        object
          [ "type" .= ("object" :: Text),
            "properties"
              .= object
                [ "message_id"
                    .= object
                      [ "type" .= ("integer" :: Text),
                        "description" .= ("[video#<id>] 标记里的消息 id" :: Text)
                      ]
                ],
            "required" .= (["message_id"] :: [Text])
          ],
      toolRun = \args -> case parseEither (withObject "args" (\o -> o .: "message_id")) args of
        Left e -> pure $ Left ("bad args: " <> T.pack e)
        Right (mid :: Int64) -> do
          rows <-
            query
              "SELECT v.mime_type, v.local_path \
              \  FROM message_videos mv \
              \  JOIN videos v USING (sha256) \
              \  WHERE mv.message_id = ? \
              \  ORDER BY mv.seg_index \
              \  LIMIT 1"
              (Only mid)
          case rows :: [(Text, Text)] of
            [] ->
              pure $
                Left
                  "这条消息没有已下载的视频（不是视频消息、还在下载中、或超过大小上限没有保存）"
            ((mime, path) : _) -> do
              ebytes <- liftIO (try @IOException (BS.readFile (blobRoot </> T.unpack path)))
              case ebytes of
                Left e -> pure $ Left ("视频读取失败: " <> T.pack (show e))
                Right bytes -> attach mid mime bytes
    }
  where
    attach mid mime bytes = do
      let label = "[视频#" <> T.pack (show mid) <> "]:"
          dataUrl = "data:" <> mime <> ";base64," <> TE.decodeUtf8 (B64.encode bytes)
      ok <- queueToolImage dc (ToolImage label dataUrl)
      if not ok
        then pure $ Left "本次任务的附件配额（8 个）已用完"
        else do
          logInfo "view_video" $
            object ["message_id" .= mid, "bytes" .= BS.length bytes]
          pure . Right $
            object
              [ "attached" .= True,
                "bytes" .= BS.length bytes,
                "note" .= ("视频已附在下一条消息里" :: Text)
              ]
