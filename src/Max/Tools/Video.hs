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
import Data.Aeson.Types (parseEither)
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
import Max.ConversationScope (conversationScopeFor)
import Max.DB.Media (StoredVideo (..), fetchMessageVideoInScope)
import Max.Effects.Blob (Blob, blobRefFromSha256, readBlob)
import Max.Effects.LLM (ToolSpec (..))
import Max.Effects.ToolOutput (InlineMedia (..), ToolOutput, queueInlineMedia)
import Max.Effects.Tools (Tool (..))
import Max.Time (fmtDurationSec)
import Max.ToolContext (ToolContext, toolGroupId)

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
      toolRun = \args -> case parseEither (withObject "args" (\o -> o .: "message_id")) args of
        Left e -> pure $ Left ("bad args: " <> T.pack e)
        Right (mid :: Int64) -> do
          mVideo <- fetchMessageVideoInScope scope mid
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
    scope = conversationScopeFor (toolGroupId dc)

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
          [ "看一条群里发的视频：传 [video#<id>] 里的 <id>，整段视频会附在",
            "下一条消息里给你看（占用本次任务 8 个附件配额中的 1 个）。",
            "同一个视频看一次就够了。"
          ],
      specSchema =
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
          ]
    }
