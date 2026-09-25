-- | Bilibili metadata lookup from IDs, links or share cards. with_video also
-- downloads a progressive MP4 and attaches it for multimodal profiles.
module Max.Tools.Bilibili
  ( bilibiliToolsFor,
  )
where

import Data.Aeson
import Data.Aeson.Types (parseEither)
import Data.ByteString qualified as BS
import Data.ByteString.Base64 qualified as B64
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (TimeZone)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Effectful
import Effectful.Log
import Max.Bilibili
import Max.Effects.Http
  ( Http,
    getBilibiliMedia,
    renderDownloadError,
  )
import Max.Effects.ToolOutput
  ( InlineMedia (..),
    ToolOutput,
    queueInlineMedia,
  )
import Max.Effects.Tools (Tool (..), ToolRunner (..))
import Max.Media.Vision (VideoAttachment (..))
import Max.Time (fmtDateHM)
import Max.ToolContext (ToolContext, toolMultimodal)
import Max.Tools.Schema
  ( boolParam,
    stringParam,
    toolObject,
    withKeys,
  )

bilibiliToolsFor ::
  (Http :> es, Log :> es, ToolOutput :> es) =>
  TimeZone ->
  ToolContext ->
  -- | Prepare a downloaded stream for the current profile.
  (BS.ByteString -> Eff es (Either Text VideoAttachment)) ->
  [Tool es]
bilibiliToolsFor tz dc prepare = [viewBilibiliTool tz dc prepare]

-- | Same budget as QQ videos (see 'Max.Images'): Kimi caps the whole
-- request body at a documented 100MB, so 70MB raw ≈ 93MB base64 plus
-- prompt headroom.  At the 480p tier that's roughly 25-35 minutes.
maxStreamBytes :: Int
maxStreamBytes = 70 * 1024 * 1024

topCommentCount :: Int
topCommentCount = 15

viewBilibiliTool ::
  (Http :> es, Log :> es, ToolOutput :> es) =>
  TimeZone ->
  ToolContext ->
  (BS.ByteString -> Eff es (Either Text VideoAttachment)) ->
  Tool es
viewBilibiliTool tz dc prepare =
  Tool
    { toolName = "view_bilibili",
      toolDescription =
        T.unwords
          [ "看一个B站视频：标题、UP主、数据、热评，默认把整段视频（480p）附在",
            "下一条消息里给你看（占 1 个附件配额）——聊画面内容先真的看一眼。",
            "url 接受完整链接、BV号、b23.tv 短链。只要文本信息传 with_video=false；",
            "时长上限等细节见 use_skill 的 web 手册。"
          ],
      toolSchema =
        toolObject
          [ ("url", stringParam "B站视频链接 / BV号 / b23.tv 短链"),
            ( "with_video",
              withKeys ["default" .= True] (boolParam "默认 true：下载整段视频附给你看（仅多模态可用）。false = 只要文本信息。")
            )
          ]
          ["url"],
      toolRunner = LegacyRunner $ \args -> case parseEither (withObject "args" parseArgs) args of
        Left e -> pure $ Left ("bad args: " <> T.pack e)
        Right (rawUrl, withVideo) ->
          case findBiliRef rawUrl of
            Nothing -> pure $ Left "没在 url 里找到B站视频引用（BV号 / bilibili.com/video 链接 / b23.tv 短链）"
            Just ref0 -> do
              eref <- case ref0 of
                RefShort short -> resolveShort short
                r -> pure (Right r)
              case eref of
                Left err -> pure (Left err)
                Right ref ->
                  fetchVideoInfo ref >>= \case
                    Left err -> pure (Left err)
                    Right info -> do
                      -- Comments are garnish: a closed section or API
                      -- refusal degrades to empty with the reason noted.
                      ecomments <- fetchTopComments info.bvAid topCommentCount
                      videoPart <-
                        if withVideo
                          then attachStream info
                          else pure ["video_attached" .= False]
                      logInfo "view_bilibili" $
                        object ["bvid" .= info.bvBvid, "with_video" .= withVideo]
                      pure . Right . object $
                        [ "bvid" .= info.bvBvid,
                          "title" .= info.bvTitle,
                          "up" .= info.bvUp,
                          "duration" .= fmtDuration info.bvDurationSec,
                          "pubdate" .= fmtDateHM tz (posixSecondsToUTCTime (fromIntegral info.bvPubdate)),
                          "stats"
                            .= object
                              [ "view" .= info.bvStat.bsView,
                                "like" .= info.bvStat.bsLike,
                                "coin" .= info.bvStat.bsCoin,
                                "favorite" .= info.bvStat.bsFavorite,
                                "danmaku" .= info.bvStat.bsDanmaku,
                                "reply" .= info.bvStat.bsReply,
                                "share" .= info.bvStat.bsShare
                              ],
                          "desc" .= shorten 800 info.bvDesc,
                          "top_comments" .= commentsJson ecomments
                        ]
                          <> ["parts" .= info.bvParts | info.bvParts > 1]
                          <> videoPart
    }
  where
    parseArgs o = (,) <$> o .: "url" <*> o .:? "with_video" .!= True

    commentsJson = \case
      Left err -> toJSON ("(热评获取失败: " <> err <> ")")
      Right cs ->
        toJSON
          [ object ["user" .= c.bcUser, "likes" .= c.bcLikes, "text" .= shorten 300 c.bcText]
          | c <- cs
          ]

    attachStream info
      | not (toolMultimodal dc) =
          pure
            [ "video_attached" .= False,
              "video_note" .= ("当前模型不是多模态，看不了画面" :: Text)
            ]
      | otherwise =
          fetchStreamUrl info.bvBvid info.bvCid >>= \case
            Left err -> pure ["video_attached" .= False, "video_note" .= ("取流失败: " <> err)]
            Right (streamUrl, size)
              | size > fromIntegral maxStreamBytes ->
                  pure
                    [ "video_attached" .= False,
                      "video_note"
                        .= ( "视频流 "
                               <> T.pack (show (size `div` (1024 * 1024)))
                               <> "MB，超过附件上限没有附上" ::
                               Text
                           )
                    ]
              | otherwise ->
                  getBilibiliMedia streamUrl biliHeaders maxStreamBytes >>= \case
                    Left err -> pure ["video_attached" .= False, "video_note" .= ("视频下载失败: " <> renderDownloadError err)]
                    Right (bytes, _) ->
                      prepare bytes >>= \case
                        Left failure -> pure ["video_attached" .= False, "video_note" .= ("视频准备失败: " <> failure)]
                        Right video -> do
                          let label = "[B站 " <> info.bvBvid <> " " <> info.bvTitle <> "]" <> video.attachmentNote <> ":"
                          ok <- queueInlineMedia (InlineMedia label video.attachmentDataUrl video.attachmentTokens)
                          if ok
                            then do
                              logInfo "view_bilibili: stream attached" $
                                object ["bvid" .= info.bvBvid, "bytes" .= BS.length bytes, "vision_tokens" .= video.attachmentTokens]
                              pure ["video_attached" .= True, "video_note" .= ("视频已附在下一条消息里" <> video.attachmentNote)]
                            else pure ["video_attached" .= False, "video_note" .= ("本次任务的附件配额（8 个）已用完" :: Text)]

    fmtDuration :: Int -> Text
    fmtDuration s
      | s >= 3600 = tshow (s `div` 3600) <> ":" <> pad ((s `mod` 3600) `div` 60) <> ":" <> pad (s `mod` 60)
      | otherwise = tshow (s `div` 60) <> ":" <> pad (s `mod` 60)
    pad n = (if n < 10 then "0" else "") <> tshow n
    tshow = T.pack . show

    shorten :: Int -> Text -> Text
    shorten n t
      | T.length t <= n = t
      | otherwise = T.take n t <> "…"
