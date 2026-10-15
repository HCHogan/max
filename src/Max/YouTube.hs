-- | Anonymous YouTube metadata and transcripts through the iOS player
-- client.  The web client's caption URLs carry @exp=xpe@ and answer an
-- empty body without a proof-of-origin token; the iOS client's do not.
-- Video streams are out of scope: the sandbox's yt-dlp downloads those.
module Max.YouTube
  ( findYouTubeId,
    YouTubeVideo (..),
    CaptionTrack (..),
    TranscriptLine (..),
    fetchPlayer,
    fetchTranscript,
    pickTrack,
    trackMatches,

    -- * Pure parsers (exposed for tests)
    parsePlayer,
    parseTranscript,
    renderTranscript,
  )
where

import Control.Applicative ((<|>))
import Data.Aeson
import Data.Aeson.Types (Parser, parseEither)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Char (isAlphaNum, isSpace, ord, toLower)
import Data.Foldable (asum)
import Data.Int (Int64)
import Data.List (findIndex, sortOn)
import Data.Maybe (fromMaybe, listToMaybe, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Effectful
import Max.Effects.Http (Http, getBytesWith, postBytesWith, renderDownloadError)
import Text.Read (readMaybe)

-- | The 11-character video ID in a link (watch, youtu.be, shorts, live,
-- embed) or a bare ID.
findYouTubeId :: Text -> Maybe Text
findYouTubeId raw
  | Just v <- exactId (T.strip raw) = Just v
  | otherwise = asum (map after markers) <|> watchParam
  where
    markers = ["youtu.be/", "youtube.com/shorts/", "youtube.com/live/", "youtube.com/embed/", "youtube.com/v/", "youtube-nocookie.com/embed/"]
    after marker = case T.breakOn marker raw of
      (_, rest)
        | T.null rest -> Nothing
        | otherwise -> idPrefix (T.drop (T.length marker) rest)
    watchParam = case T.breakOn "youtube.com/watch" raw of
      (_, rest)
        | T.null rest -> Nothing
        | otherwise ->
            let query = T.drop 1 (T.dropWhile (/= '?') (T.takeWhile (not . isSpace) rest))
             in asum [idPrefix v | param <- T.splitOn "&" query, Just v <- [T.stripPrefix "v=" param]]
    exactId t = if T.length t == 11 && T.all idChar t then Just t else Nothing
    idPrefix t =
      let candidate = T.take 11 t
       in if T.length candidate == 11 && T.all idChar candidate && maybe True (not . idChar . fst) (T.uncons (T.drop 11 t))
            then Just candidate
            else Nothing
    idChar c = isAlphaNum c && c < '\x80' || c == '-' || c == '_'

data CaptionTrack = CaptionTrack
  { ctBaseUrl :: !Text,
    ctLanguage :: !Text,
    ctName :: !Text,
    -- | Speech recognition rather than uploaded captions.
    ctAuto :: !Bool
  }
  deriving stock (Show, Eq)

data YouTubeVideo = YouTubeVideo
  { ytId :: !Text,
    ytTitle :: !Text,
    ytChannel :: !Text,
    ytDurationSec :: !Int,
    ytViews :: !(Maybe Int64),
    ytDescription :: !Text,
    ytLive :: !Bool,
    ytTracks :: ![CaptionTrack],
    -- | Index into 'ytTracks' of the default audio track's own captions,
    -- i.e. the spoken language.
    ytOriginal :: !(Maybe Int)
  }
  deriving stock (Show, Eq)

-- | One caption cue: its start in milliseconds and its text.
data TranscriptLine = TranscriptLine
  { tlStartMs :: !Int,
    tlText :: !Text
  }
  deriving stock (Show, Eq)

iosVersion :: Text
iosVersion = "20.10.4"

iosHeaders :: [(Text, Text)]
iosHeaders =
  [ ("User-Agent", "com.google.ios.youtube/" <> iosVersion <> " (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)"),
    ("X-YouTube-Client-Name", "5"),
    ("X-YouTube-Client-Version", iosVersion)
  ]

maxPlayerBytes :: Int
maxPlayerBytes = 8 * 1024 * 1024

maxTranscriptBytes :: Int
maxTranscriptBytes = 16 * 1024 * 1024

fetchPlayer :: (Http :> es) => Text -> Eff es (Either Text YouTubeVideo)
fetchPlayer videoId =
  postBytesWith
    "https://www.youtube.com/youtubei/v1/player?prettyPrint=false"
    (("Content-Type", "application/json") : iosHeaders)
    (LBS.toStrict (encode body))
    maxPlayerBytes
    >>= \case
      Left err -> pure (Left ("YouTube 播放器接口请求失败: " <> renderDownloadError err))
      Right (bytes, _) -> pure (either (Left . ("YouTube 响应不是 JSON: " <>) . T.pack) parsePlayer (eitherDecodeStrict' bytes))
  where
    body =
      object
        [ "context"
            .= object
              [ "client"
                  .= object
                    [ "clientName" .= ("IOS" :: Text),
                      "clientVersion" .= iosVersion,
                      "deviceMake" .= ("Apple" :: Text),
                      "deviceModel" .= ("iPhone16,2" :: Text),
                      "osName" .= ("iPhone" :: Text),
                      "osVersion" .= ("18.3.2.22D82" :: Text),
                      "hl" .= ("en" :: Text),
                      "gl" .= ("US" :: Text)
                    ]
              ],
          "videoId" .= videoId,
          "contentCheckOk" .= True,
          "racyCheckOk" .= True
        ]

-- | Cues of one track.  (YouTube's machine translation, @&tlang=@, answers
-- 429 to anonymous clients, so the model translates instead.)
fetchTranscript :: (Http :> es) => CaptionTrack -> Eff es (Either Text [TranscriptLine])
fetchTranscript track =
  getBytesWith url iosHeaders maxTranscriptBytes >>= \case
    Left err -> pure (Left ("字幕下载失败: " <> renderDownloadError err))
    Right (bytes, _)
      | BS.null bytes -> pure (Left "字幕地址返回了空内容（YouTube 可能又改了策略）")
      | otherwise -> pure (either (Left . ("字幕不是 JSON: " <>) . T.pack) parseTranscript (eitherDecodeStrict' bytes))
  where
    url = track.ctBaseUrl <> "&fmt=json3"

-- | The track to read: one in the requested language (uploaded captions
-- before speech recognition), else uploaded Chinese captions, else the
-- spoken language, else uploaded captions, else anything.
pickTrack :: Maybe Text -> YouTubeVideo -> Maybe CaptionTrack
pickTrack wanted video =
  listToMaybe $
    maybe [] (\lang -> sortOn ctAuto (filter (trackMatches lang) tracks)) requested
      <> filter (trackMatches "zh") manual
      <> maybe [] pure original
      <> manual
      <> tracks
  where
    requested = case T.strip <$> wanted of
      Just lang | not (T.null lang) -> Just lang
      _ -> Nothing
    tracks = video.ytTracks
    manual = filter (not . ctAuto) tracks
    original = video.ytOriginal >>= \i -> listToMaybe (drop i tracks)

-- | Whether a track is in @lang@, ignoring case: "zh" matches "zh-Hans".
trackMatches :: Text -> CaptionTrack -> Bool
trackMatches lang track =
  let wanted = T.map toLower lang
      code = T.map toLower track.ctLanguage
   in code == wanted || (wanted <> "-") `T.isPrefixOf` code

--------------------------------------------------------------------------------
-- Pure response parsers.

parsePlayer :: Value -> Either Text YouTubeVideo
parsePlayer v = case parseEither player v of
  Left e -> Left ("YouTube 响应结构异常: " <> T.pack e)
  Right (Left refusal) -> Left refusal
  Right (Right video) -> Right video
  where
    player :: Value -> Parser (Either Text YouTubeVideo)
    player = withObject "player" $ \o -> do
      status <- o .:? "playabilityStatus" >>= maybe (pure (Nothing, Nothing)) (withObject "status" (\s -> (,) <$> s .:? "status" <*> s .:? "reason"))
      details <- o .:? "videoDetails"
      case details of
        Nothing ->
          pure . Left $
            "YouTube 拒绝: "
              <> fromMaybe "无视频信息" (fst status)
              <> maybe "" (" — " <>) (snd status)
        Just d -> do
          (tracks, original) <- o .:? "captions" >>= maybe (pure ([], Nothing)) captions
          Right
            <$> ( YouTubeVideo
                    <$> d .: "videoId"
                    <*> d .:? "title" .!= ""
                    <*> d .:? "author" .!= ""
                    <*> (fromMaybe 0 . number <$> d .:? "lengthSeconds")
                    <*> (number <$> d .:? "viewCount")
                    <*> d .:? "shortDescription" .!= ""
                    <*> d .:? "isLiveContent" .!= False
                    <*> pure tracks
                    <*> pure original
                )
    -- Counts arrive as decimal strings.
    number :: (Read a) => Maybe Text -> Maybe a
    number = (>>= readMaybe . T.unpack)
    captions = withObject "captions" $ \c -> do
      list <- c .:? "playerCaptionsTracklistRenderer"
      case list of
        Nothing -> pure ([], Nothing)
        Just r -> do
          tracks <- traverse track =<< (r .:? "captionTracks" .!= [])
          audio <- r .:? "audioTracks" .!= ([] :: [Value])
          index <- r .:? "defaultAudioTrackIndex"
          own <- case index >>= \i -> listToMaybe (drop i audio) of
            Nothing -> pure Nothing
            Just a -> withObject "audioTrack" (\x -> (>>= listToMaybe) <$> x .:? "captionTrackIndices") a
          let original = own <|> findIndex ctAuto tracks
          pure (tracks, original >>= \i -> if i < length tracks then Just i else Nothing)
    track = withObject "captionTrack" $ \t -> do
      name <- t .:? "name" >>= maybe (pure Nothing) trackName
      language <- t .: "languageCode"
      kind <- t .:? "kind"
      CaptionTrack
        <$> t .: "baseUrl"
        <*> pure language
        <*> pure (fromMaybe language name)
        <*> pure (kind == Just ("asr" :: Text))
    trackName = withObject "name" $ \n -> do
      simple <- n .:? "simpleText"
      runs <- n .:? "runs" .!= ([] :: [Value])
      texts <- traverse (withObject "run" (.: "text")) runs
      pure (simple <|> (if null texts then Nothing else Just (T.concat texts)))

-- | json3 timed text: each event with segments is one cue.
parseTranscript :: Value -> Either Text [TranscriptLine]
parseTranscript v = case parseEither events v of
  Left e -> Left ("字幕解析失败: " <> T.pack e)
  Right cues -> Right cues
  where
    events = withObject "timedtext" $ \o -> do
      es <- o .:? "events" .!= []
      mapMaybe id <$> traverse cue es
    cue = withObject "event" $ \e -> do
      start <- e .:? "tStartMs" .!= 0
      segs <- e .:? "segs" .!= []
      texts <- traverse (withObject "seg" (\s -> s .:? "utf8" .!= "")) segs
      let text = T.strip (T.unwords (T.words (T.replace "\n" " " (T.concat texts))))
      pure (if T.null text then Nothing else Just (TranscriptLine start text))

-- | Cues from @fromSec@ on as paragraphs of about a minute, each led by its
-- timestamp, within @maxChars@.  The second value is where to resume when
-- the budget ran out.
renderTranscript :: Int -> Int -> [TranscriptLine] -> (Text, Maybe Int)
renderTranscript fromSec maxChars cues = go 0 [] (paragraphs (filter ((>= fromSec * 1000) . tlStartMs) cues))
  where
    go _ acc [] = (T.intercalate "\n" (reverse acc), Nothing)
    go used acc ((start, text) : rest)
      | null acc && T.length line > maxChars = (T.take maxChars line, (\(next, _) -> next `div` 1000) <$> listToMaybe rest)
      | used + T.length line > maxChars && not (null acc) = (T.intercalate "\n" (reverse acc), Just (start `div` 1000))
      | otherwise = go (used + T.length line + 1) (line : acc) rest
      where
        line = "[" <> stamp start <> "] " <> text
    paragraphs [] = []
    paragraphs (first : rest) =
      let (inside, later) = span ((< first.tlStartMs + 60000) . tlStartMs) rest
       in (first.tlStartMs, foldl joinText first.tlText (map tlText inside)) : paragraphs later
    stamp ms =
      let s = ms `div` 1000
          two n = (if n < 10 then "0" else "") <> T.pack (show n)
       in if s >= 3600
            then T.pack (show (s `div` 3600)) <> ":" <> two ((s `mod` 3600) `div` 60) <> ":" <> two (s `mod` 60)
            else two (s `div` 60) <> ":" <> two (s `mod` 60)
    -- CJK cues carry no spaces between them; Latin ones need one.
    joinText a b = case (T.unsnoc a, T.uncons b) of
      (Just (_, x), Just (y, _)) | wide x && wide y -> a <> b
      _ -> a <> " " <> b
    wide c = ord c >= 0x2E80
