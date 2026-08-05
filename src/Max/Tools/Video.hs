-- |
-- @view_video@: let a video-capable multimodal profile watch a group
-- video.  Videos are downloaded at receive time by the media worker
-- (same pool as images) into the content-addressed blob store; this
-- tool reads the local copy and attaches it whole, as an inline
-- @data:video\/...@ block — models with native video input (Kimi K3,
-- Qwen-VL, …) take it directly.
module Max.Tools.Video
  ( videoToolsFor,
    viewVideoSpec,
  )
where

import Data.Aeson
import Data.Aeson.Types (Parser, parseEither)
import Data.ByteString qualified as BS
import Data.ByteString.Base64 qualified as B64
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Effectful
import Effectful.Exception (IOException, try)
import Effectful.Log
import Effectful.PostgreSQL (WithConnection)
import Max.DB.Media (StoredVideo (..), fetchMessageVideoInScope)
import Max.Effects.Blob (Blob, blobRefFromSha256, readBlob)
import Max.Effects.LLM (ToolSpec (..))
import Max.Effects.ToolOutput (InlineMedia (..), ToolOutput, queueInlineMedia)
import Max.Effects.Tools (Tool (..))
import Max.Tools.Schema (integerParam, toolObject)
import Max.Time (fmtDurationSec)
import Max.ToolContext (ToolContext, toolConversationScope)

videoToolsFor ::
  (Blob :> es, WithConnection :> es, Log :> es, ToolOutput :> es, IOE :> es) =>
  ToolContext ->
  [Tool es]
videoToolsFor dc = [viewVideoTool dc]

viewVideoTool ::
  (Blob :> es, WithConnection :> es, Log :> es, ToolOutput :> es, IOE :> es) =>
  ToolContext ->
  Tool es
viewVideoTool dc =
  Tool
    { toolName = viewVideoSpec.specName,
      toolDescription = viewVideoSpec.specDescription,
      toolSchema = viewVideoSpec.specSchema,
      toolRun = \args -> case parseEither (withObject "args" parseArgs) args of
        Left e -> pure $ Left ("bad args: " <> T.pack e)
        Right (mid, seg) -> do
          mVideo <- fetchMessageVideoInScope scope mid seg
          case mVideo of
            Nothing ->
              pure $
                Left
                  "这条消息没有已下载的视频（不是视频消息、还在下载中、或超过大小上限没有保存）"
            Just video -> case blobRefFromSha256 video.storedVideoSha256 of
              Nothing -> pure $ Left "视频存储引用无效"
              Just ref -> do
                ebytes <- try @IOException (readBlob ref)
                case ebytes of
                  Left e -> pure $ Left ("视频读取失败: " <> T.pack (show e))
                  Right bytes ->
                    attach
                      mid
                      video.storedVideoDurationSeconds
                      video.storedVideoMime
                      bytes
    }
  where
    scope = toolConversationScope dc

    parseArgs o = (,) <$> (o .: "message_id" :: Parser Int64) <*> o .:? "seg_index"

    -- Stated duration beats the model's own sampled-frame guess.
    attach mid mDur mime bytes = do
      let label =
            "[视频#"
              <> T.pack (show mid)
              <> maybe "" (\d -> "，时长 " <> fmtDurationSec d) mDur
              <> "]:"
          dataUrl = "data:" <> mime <> ";base64," <> TE.decodeUtf8 (B64.encode bytes)
      ok <- queueInlineMedia (InlineMedia label dataUrl)
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

-- | Protocol-neutral metadata advertised for @view_video@.  The live
-- runner and generated wire examples share this single value.
viewVideoSpec :: ToolSpec
viewVideoSpec =
  ToolSpec
    { specName = "view_video",
      specDescription =
        T.unwords
          [ "看一条群里发的视频：把 [video#<id>.<seg>] 里的两个数字分别传给",
            "message_id 和 seg_index，整段视频会附在下一条消息里给你看",
            "（占用本次任务 8 个附件配额中的 1 个）。同一个视频看一次就够了。"
          ],
      specSchema =
        toolObject
          [ ("message_id", integerParam "[video#<id>.<seg>] 里 . 前面那个数字"),
            ("seg_index", integerParam "[video#<id>.<seg>] 里 . 后面那个数字；省略就取这条消息的第一个视频")
          ]
          ["message_id"]
    }
