-- |
-- @view_video@: let a video-capable multimodal profile watch a group
-- video.  Videos are downloaded at receive time by the media worker
-- (same pool as images) into the content-addressed blob store.  The host
-- supplies the attachment: the stored video as-is, or, under a declared
-- vision envelope, a cached rendition of the requested window that fits one
-- item (compressed into a fast overview when the window is too long).
module Max.Tools.Video
  ( videoToolsFor,
    viewVideoSpec,
  )
where

import Data.Aeson
import Data.Aeson.Types (Parser, parseEither)
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as T
import Effectful
import Effectful.Log
import Max.Effects.MediaQuery (MediaQuery, readVideo)
import Max.Effects.ToolOutput
  ( InlineMedia (..),
    ToolOutput,
    queueInlineMedia,
  )
import Max.Effects.Tools (Tool (..), ToolRunner (..))
import Max.Media.Types (StoredVideo (..))
import Max.Media.Vision (VideoAttachment (..), VideoWindow (..))
import Max.Tool.Types (ToolSpec (..))
import Max.Tools.Schema (integerParam, numberParam, toolObject)

videoToolsFor ::
  (MediaQuery :> es, Log :> es, ToolOutput :> es) =>
  (StoredVideo -> VideoWindow -> Eff es (Either Text VideoAttachment)) ->
  [Tool es]
videoToolsFor attach = [viewVideoTool attach]

viewVideoTool ::
  (MediaQuery :> es, Log :> es, ToolOutput :> es) =>
  (StoredVideo -> VideoWindow -> Eff es (Either Text VideoAttachment)) ->
  Tool es
viewVideoTool attach =
  Tool
    { toolName = viewVideoSpec.specName,
      toolDescription = viewVideoSpec.specDescription,
      toolSchema = viewVideoSpec.specSchema,
      toolRunner = LegacyRunner $ \args -> case parseEither (withObject "args" parseArgs) args of
        Left e -> pure $ Left ("bad args: " <> T.pack e)
        Right (mid, seg, window) -> do
          mVideo <- readVideo mid seg
          case mVideo of
            Nothing ->
              pure $
                Left
                  "这条消息没有已下载的视频（不是视频消息、还在下载中、或超过大小上限没有保存）"
            Just video ->
              attach video window >>= \case
                Left failure -> pure (Left ("视频准备失败：" <> failure))
                Right attachment -> do
                  -- Stated duration beats the model's own sampled-frame guess.
                  let label = "[视频#" <> T.pack (show mid) <> "]" <> attachment.attachmentNote <> ":"
                  ok <- queueInlineMedia (InlineMedia label attachment.attachmentDataUrl attachment.attachmentTokens)
                  if not ok
                    then pure $ Left "本次任务的附件配额（8 个）已用完"
                    else do
                      logInfo "view_video" $
                        object ["message_id" .= mid, "vision_tokens" .= attachment.attachmentTokens]
                      pure . Right $
                        object
                          [ "attached" .= True,
                            "label" .= label,
                            "vision_tokens" .= attachment.attachmentTokens,
                            "note" .= ("视频已附在下一条消息里" :: Text)
                          ]
    }
  where
    parseArgs :: Object -> Parser (Int64, Maybe Int, VideoWindow)
    parseArgs o = do
      mid <- o .: "message_id"
      seg <- o .:? "seg_index"
      start <- o .:? "start_seconds"
      end <- o .:? "end_seconds"
      pure (mid, seg, VideoWindow (maybe 0 (max 0) start) end)

-- | Protocol-neutral metadata advertised for @view_video@.  The live
-- runner and generated wire examples share this single value.
viewVideoSpec :: ToolSpec
viewVideoSpec =
  ToolSpec
    { specName = "view_video",
      specDescription =
        T.unwords
          [ "看一条群里发的视频：把 [video#<id>.<seg>] 里的两个数字分别传给",
            "message_id 和 seg_index，视频会附在下一条消息里给你看",
            "（占用本次任务 8 个附件配额中的 1 个）。太长的视频会压缩成快进概览，",
            "标签会写明倍速；要看清某一段，用 start_seconds/end_seconds 按原速看那一段。",
            "同一段看一次就够了。"
          ],
      specSchema =
        toolObject
          [ ("message_id", integerParam "[video#<id>.<seg>] 里 . 前面那个数字"),
            ("seg_index", integerParam "[video#<id>.<seg>] 里 . 后面那个数字；省略就取这条消息的第一个视频"),
            ("start_seconds", numberParam "只看从这一秒开始的片段；省略从头开始"),
            ("end_seconds", numberParam "只看到这一秒为止；省略看到结尾")
          ]
          ["message_id"]
    }
