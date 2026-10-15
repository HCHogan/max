-- | YouTube metadata and timestamped transcripts from links or IDs.  No
-- frames: the web skill sends video watching through the sandbox's yt-dlp
-- and view_video.
module Max.Tools.YouTube
  ( youtubeToolsFor,
  )
where

import Data.Aeson
import Data.Aeson.Types (parseEither)
import Data.Text (Text)
import Data.Text qualified as T
import Effectful
import Effectful.Log
import Max.Effects.Http (Http)
import Max.Effects.Tools (Tool (..), ToolRunner (..))
import Max.Tools.Schema
  ( boundedIntegerParam,
    integerParam,
    stringParam,
    toolObject,
    withKeys,
  )
import Max.YouTube

youtubeToolsFor :: (Http :> es, Log :> es) => [Tool es]
youtubeToolsFor = [viewYouTubeTool]

defaultTranscriptChars :: Int
defaultTranscriptChars = 30000

viewYouTubeTool :: (Http :> es, Log :> es) => Tool es
viewYouTubeTool =
  Tool
    { toolName = "view_youtube",
      toolDescription =
        T.unwords
          [ "读一个 YouTube 视频：标题、频道、时长、播放量、简介，加带时间戳的字幕全文",
            "（默认原声语言，lang 可指定）。只有文字不含画面，要看画面见 use_skill 的 web 手册。"
          ],
      toolSchema =
        toolObject
          [ ("url", stringParam "YouTube 链接（watch / youtu.be / shorts / live）或 11 位视频 ID"),
            ("lang", stringParam "字幕语言代码，例如 zh、en、ja；没有这种字幕时退回原声字幕，自己翻译"),
            ("start_seconds", integerParam "从这一秒开始取字幕；被截断时按返回的 next_start_seconds 接着读"),
            ("max_chars", withKeys ["description" .= ("字幕文字预算" :: Text)] (boundedIntegerParam 2000 60000 defaultTranscriptChars))
          ]
          ["url"],
      toolRunner = LegacyRunner $ \args -> case parseEither (withObject "args" parseArgs) args of
        Left e -> pure $ Left ("bad args: " <> T.pack e)
        Right (rawUrl, lang, from, budget) -> case findYouTubeId rawUrl of
          Nothing -> pure $ Left "没在 url 里找到 YouTube 视频（watch?v= / youtu.be / shorts / live 链接，或 11 位 ID）"
          Just videoId ->
            fetchPlayer videoId >>= \case
              Left err -> pure (Left err)
              Right video -> do
                transcript <- case pickTrack lang video of
                  Nothing -> pure ["transcript_note" .= ("这个视频没有字幕（上传者没传，也没有自动字幕）" :: Text)]
                  Just track ->
                    fetchTranscript track >>= \case
                      Left err -> pure ["transcript_note" .= err]
                      Right cues ->
                        let (text, next) = renderTranscript (max 0 from) (clamp budget) cues
                         in pure $
                              [ "transcript"
                                  .= object
                                    ( [ "lang" .= track.ctLanguage,
                                        "name" .= track.ctName,
                                        "auto" .= track.ctAuto,
                                        "text" .= text
                                      ]
                                        <> ["next_start_seconds" .= n | Just n <- [next]]
                                    )
                              ]
                                <> [ "transcript_note" .= ("没有 " <> l <> " 字幕，给的是 " <> track.ctName <> "，需要就自己翻译")
                                   | Just l <- [lang],
                                     not (T.null (T.strip l)),
                                     not (trackMatches (T.strip l) track)
                                   ]
                logInfo "view_youtube" $
                  object ["video_id" .= videoId, "tracks" .= length video.ytTracks, "lang" .= lang]
                pure . Right . object $
                  [ "video_id" .= video.ytId,
                    "title" .= video.ytTitle,
                    "channel" .= video.ytChannel,
                    "duration" .= fmtDuration video.ytDurationSec,
                    "views" .= video.ytViews,
                    "description" .= shorten 1500 video.ytDescription
                  ]
                    <> ["live" .= True | video.ytLive]
                    <> transcript
                    <> ["other_langs" .= map ctLanguage (take 20 video.ytTracks) | length video.ytTracks > 1]
    }
  where
    parseArgs o =
      (,,,)
        <$> o .: "url"
        <*> o .:? "lang"
        <*> o .:? "start_seconds" .!= 0
        <*> o .:? "max_chars" .!= defaultTranscriptChars

    clamp = max 2000 . min 60000

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
