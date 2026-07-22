-- |
-- Bilibili adapter: link recognition, the public (login-free) APIs
-- for video metadata / top comments / a progressive low-quality
-- stream URL, and the headers bilibili's origin insists on.
--
-- The stream side deliberately requests @platform=html5@: those
-- quality tiers (≤720p) come as a single progressive MP4 — no DASH
-- audio/video muxing — and work without a login cookie.  If bilibili
-- starts 403-ing the anonymous APIs, the place to add a cookie is
-- 'biliHeaders'.
module Max.Bilibili
  ( BiliRef (..),
    findBiliRef,
    BiliVideo (..),
    BiliStat (..),
    BiliComment (..),
    fetchVideoInfo,
    fetchTopComments,
    fetchStreamUrl,
    resolveShort,
    biliHeaders,
    -- * Pure parsers (exposed for tests)
    parseVideoInfo,
    parseComments,
    parseStreamUrl,
  )
where

import Data.Aeson
import Data.Aeson.Types (Parser, parseEither)
import Data.Char (isAlphaNum, isDigit)
import Data.Int (Int64)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Effectful
import Max.Effects.Http (Http, getBytesWith, getFinalUrl)

-- | A bilibili video reference found in message text.
data BiliRef
  = RefBvid !Text
  | RefAvid !Int64
  | -- | A @b23.tv@ short link (full URL) — resolve via redirect.
    RefShort !Text
  deriving stock (Show, Eq)

-- | Scan free text for a bilibili video reference.  BV ids win over
-- av ids win over b23 short links (a full video URL contains its BV
-- id, so URL forms need no case of their own).
findBiliRef :: Text -> Maybe BiliRef
findBiliRef t =
  (RefBvid <$> findBv t)
    <|> (RefAvid <$> findAv t)
    <|> (RefShort <$> findB23 t)
  where
    (<|>) l r = maybe r Just l

-- | @BV@ + 10 alphanumerics, wherever it appears.
findBv :: Text -> Maybe Text
findBv t = case T.breakOn "BV" t of
  (_, rest)
    | T.null rest -> Nothing
    | otherwise ->
        let body = T.take 10 (T.drop 2 rest)
         in if T.length body == 10 && T.all isAlphaNum body
              then Just ("BV" <> body)
              else findBv (T.drop 2 rest)

-- | @av@ + digits, only in the URL-path form (bare "av" prose would
-- false-positive constantly).
findAv :: Text -> Maybe Int64
findAv t = case T.breakOn "/video/av" t of
  (_, rest)
    | T.null rest -> Nothing
    | otherwise ->
        let digits = T.takeWhile isDigit (T.drop 9 rest)
         in if T.null digits
              then Nothing
              else case reads (T.unpack digits) of
                [(n, "")] -> Just n
                _ -> Nothing

findB23 :: Text -> Maybe Text
findB23 t = case T.breakOn "b23.tv/" t of
  (_, rest)
    | T.null rest -> Nothing
    | otherwise ->
        let tok = T.takeWhile isAlphaNum (T.drop 7 rest)
         in if T.null tok
              then Nothing
              else Just ("https://b23.tv/" <> tok)

-- | Follow a b23.tv short link one redirect hop and re-scan the
-- target URL for the real reference.
resolveShort :: Http :> es => Text -> Eff es (Either Text BiliRef)
resolveShort url =
  getFinalUrl url >>= \case
    Left err -> pure (Left ("b23 短链解析失败: " <> err))
    Right loc -> case findBiliRef loc of
      Just r@(RefBvid _) -> pure (Right r)
      Just r@(RefAvid _) -> pure (Right r)
      _ -> pure (Left ("b23 短链指向的不是视频页: " <> T.take 120 loc))

--------------------------------------------------------------------------------
-- API surface.

data BiliStat = BiliStat
  { bsView :: !Int64,
    bsDanmaku :: !Int64,
    bsReply :: !Int64,
    bsFavorite :: !Int64,
    bsCoin :: !Int64,
    bsShare :: !Int64,
    bsLike :: !Int64
  }
  deriving stock (Show, Eq)

data BiliVideo = BiliVideo
  { bvBvid :: !Text,
    bvAid :: !Int64,
    -- | First page's cid — what 'fetchStreamUrl' needs.
    bvCid :: !Int64,
    bvTitle :: !Text,
    bvDesc :: !Text,
    bvUp :: !Text,
    bvDurationSec :: !Int,
    -- | Unix seconds.
    bvPubdate :: !Int64,
    -- | Number of 分P parts.
    bvParts :: !Int,
    bvStat :: !BiliStat
  }
  deriving stock (Show, Eq)

data BiliComment = BiliComment
  { bcUser :: !Text,
    bcLikes :: !Int64,
    bcText :: !Text
  }
  deriving stock (Show, Eq)

-- | Headers bilibili's API and CDN insist on; anonymous otherwise.
biliHeaders :: [(Text, Text)]
biliHeaders =
  [ ("User-Agent", "Mozilla/5.0 (X11; Linux x86_64; rv:130.0) Gecko/20100101 Firefox/130.0"),
    ("Referer", "https://www.bilibili.com/")
  ]

-- | Cap on API response bodies — metadata, not media.
maxApiBytes :: Int
maxApiBytes = 4 * 1024 * 1024

getJson :: Http :> es => Text -> Eff es (Either Text Value)
getJson url =
  getBytesWith url biliHeaders maxApiBytes >>= \case
    Left err -> pure (Left err)
    Right (bytes, _) -> case eitherDecodeStrict' bytes of
      Left e -> pure (Left ("响应不是 JSON: " <> T.pack e))
      Right v -> pure (Right v)

fetchVideoInfo :: Http :> es => BiliRef -> Eff es (Either Text BiliVideo)
fetchVideoInfo ref = do
  let q = case ref of
        RefBvid bv -> Just ("bvid=" <> bv)
        RefAvid av -> Just ("aid=" <> T.pack (show av))
        RefShort _ -> Nothing
  case q of
    Nothing -> pure (Left "内部错误：短链应先 resolveShort")
    Just query' ->
      fmap (>>= parseVideoInfo) $
        getJson ("https://api.bilibili.com/x/web-interface/view?" <> query')

-- | Top comments by like count, first page.  A closed comment section
-- (or any API refusal) is a 'Left' the caller may degrade to empty.
fetchTopComments :: Http :> es => Int64 -> Int -> Eff es (Either Text [BiliComment])
fetchTopComments aid n =
  fmap (>>= parseComments n) $
    getJson
      ( "https://api.bilibili.com/x/v2/reply?type=1&sort=2&ps="
          <> T.pack (show n)
          <> "&oid="
          <> T.pack (show aid)
      )

-- | Progressive MP4 URL + its size for the first page of a video.
fetchStreamUrl :: Http :> es => Text -> Int64 -> Eff es (Either Text (Text, Int64))
fetchStreamUrl bvid cid =
  fmap (>>= parseStreamUrl) $
    getJson
      ( "https://api.bilibili.com/x/player/playurl?platform=html5&high_quality=1&qn=32&bvid="
          <> bvid
          <> "&cid="
          <> T.pack (show cid)
      )

--------------------------------------------------------------------------------
-- Pure response parsers.

-- | Unwrap bilibili's @{code, message, data}@ envelope.
apiData :: Value -> Either Text Value
apiData v = case parseEither envelope v of
  Left e -> Left ("响应结构异常: " <> T.pack e)
  Right (0, _, Just d) -> Right d
  Right (code, msg, _) ->
    Left ("B站接口拒绝 (code " <> T.pack (show code) <> "): " <> fromMaybe "" msg)
  where
    envelope = withObject "resp" $ \o ->
      (,,) <$> (o .: "code" :: Parser Int) <*> o .:? "message" <*> o .:? "data"

parseVideoInfo :: Value -> Either Text BiliVideo
parseVideoInfo v = do
  d <- apiData v
  case parseEither video d of
    Left e -> Left ("视频信息解析失败: " <> T.pack e)
    Right x -> Right x
  where
    video = withObject "video" $ \o -> do
      stat <- o .: "stat"
      owner <- o .: "owner"
      BiliVideo
        <$> o .: "bvid"
        <*> o .: "aid"
        <*> o .: "cid"
        <*> o .: "title"
        <*> o .:? "desc" .!= ""
        <*> owner .: "name"
        <*> o .: "duration"
        <*> o .: "pubdate"
        <*> o .:? "videos" .!= 1
        <*> parseStat stat
    parseStat = withObject "stat" $ \s ->
      BiliStat
        <$> s .: "view"
        <*> s .:? "danmaku" .!= 0
        <*> s .:? "reply" .!= 0
        <*> s .:? "favorite" .!= 0
        <*> s .:? "coin" .!= 0
        <*> s .:? "share" .!= 0
        <*> s .:? "like" .!= 0

parseComments :: Int -> Value -> Either Text [BiliComment]
parseComments n v = do
  d <- apiData v
  case parseEither replies d of
    Left e -> Left ("评论解析失败: " <> T.pack e)
    Right xs -> Right (take n xs)
  where
    -- data.replies can be null / absent when the section is empty.
    replies = withObject "data" $ \o -> do
      mrs <- o .:? "replies"
      case mrs of
        Nothing -> pure []
        Just Null -> pure []
        Just (Array _) -> do
          rs <- o .: "replies"
          traverse one rs
        Just _ -> pure []
    one = withObject "reply" $ \r -> do
      member <- r .: "member"
      content <- r .: "content"
      BiliComment
        <$> member .: "uname"
        <*> r .:? "like" .!= 0
        <*> content .: "message"

parseStreamUrl :: Value -> Either Text (Text, Int64)
parseStreamUrl v = do
  d <- apiData v
  case parseEither durl d of
    Left e -> Left ("播放地址解析失败: " <> T.pack e)
    Right x -> Right x
  where
    durl = withObject "data" $ \o -> do
      us <- o .: "durl"
      case us of
        (u : _) -> withObject "durl" (\x -> (,) <$> x .: "url" <*> x .:? "size" .!= 0) u
        [] -> fail "durl 为空"
