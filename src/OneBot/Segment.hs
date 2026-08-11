module OneBot.Segment
  ( Segment (..),
    CardInfo (..),
    FileSegInfo (..),
    ImageSegInfo (..),
    VideoSegInfo (..),
    parseCard,
    imageSeg,
    stickerSeg,
    isStickerImage,
    renderPlainText,
    trimEdgeSegs,
  )
where

import Control.Applicative ((<|>))
import Data.Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (Parser, typeMismatch)
import Data.Foldable (asum)
import Data.Int (Int64)
import Data.List (sortOn, unsnoc)
import Data.Maybe (catMaybes, fromMaybe, isJust)
import Data.Scientific (floatingOrInteger)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Read qualified as TR
import OneBot.Types (MessageId (..), UserId (..))

-- | A single message segment as defined by OneBot 11.
--
-- We model the segment types we actually act on, and stash anything else into
-- 'SegOther' so we round-trip and log unknown segments rather than failing.
data Segment
  = SegText !Text
  | SegAt !UserId
  | SegReply !MessageId
  | SegImage !ImageSegInfo
  | -- | A QQ built-in face.  The 'Maybe Text' is its display name
    -- ("惊讶", "撇嘴"), pulled from NapCat's @data.raw.faceText@ on
    -- inbound segments; 'Nothing' outbound (NapCat resolves the id
    -- itself) or when NapCat didn't ship one.
    SegFace !Int !(Maybe Text)
  | -- | Non-image file attached to a group message.  @data.file_id@ is
    -- the only thing guaranteed to round-trip back to QQ; @data.url@ is
    -- best-effort (sometimes inlined by NapCat, sometimes needs a
    -- separate @get_group_file_url@ call).
    SegFile !FileSegInfo
  | -- | A video message.  NapCat resolves a direct download URL at
    -- receive time (falls back to a container-local file path when it
    -- can't — those we cannot fetch).
    SegVideo !VideoSegInfo
  | -- | A structured share card (QQ lightapp @json@ segment): B站/
    -- 音乐/文章分享等.  Parsed eagerly so history lines show the
    -- title and jump URL instead of an opaque @[json]@; the raw
    -- payload is kept for round-tripping and richer future uses.
    SegCard !CardInfo
  | SegOther !Text !Value
  deriving stock (Show, Eq)

-- | What we could extract from a lightapp card.  Field meanings vary
-- by app; 'ciUrl' prefers the most link-like of
-- @qqdocurl@/@jumpUrl@/@musicUrl@/@webUrl@ within the richest meta
-- entry.
data CardInfo = CardInfo
  { -- | Lightapp id, e.g. @com.tencent.miniapp_01@ / @com.tencent.structmsg@.
    ciApp :: !Text,
    -- | Source label shown by QQ (e.g. "哔哩哔哩", "网易云音乐").
    ciTag :: !(Maybe Text),
    ciTitle :: !(Maybe Text),
    ciDesc :: !(Maybe Text),
    ciUrl :: !(Maybe Text),
    -- | Preview image URL (may lack a scheme).
    ciPreview :: !(Maybe Text),
    -- | The original inner JSON string, verbatim — 'ToJSON' emits
    -- this so the segment round-trips losslessly.
    ciRaw :: !Text
  }
  deriving stock (Show, Eq)

-- | A @video@ segment's data: NapCat file code, best-effort direct
-- URL, and size in bytes.
data VideoSegInfo = VideoSegInfo
  { vsiFile :: !Text,
    vsiUrl :: !(Maybe Text),
    vsiSize :: !(Maybe Int64)
  }
  deriving stock (Show, Eq)

data FileSegInfo = FileSegInfo
  { fsiFileId :: !Text,
    fsiName :: !Text,
    fsiSize :: !(Maybe Int64),
    fsiUrl :: !(Maybe Text)
  }
  deriving stock (Show, Eq)

-- | An @image@ segment.  Inbound, 'isiUrl' is the URL NapCat handed
-- us ('Nothing' if file-id only); outbound it's the @file@ value to
-- send (@base64://...@, @file://...@, http(s)) — OneBot 11 puts both
-- in the same slot.  'isiSubType' distinguishes a real photo (0)
-- from a saved sticker / 动画表情 (1); NapCat also ships a
-- 'isiSummary' like @[动画表情]@ for the latter.  Both round-trip so
-- nothing is lost at persist time.
data ImageSegInfo = ImageSegInfo
  { isiUrl :: !(Maybe Text),
    isiSubType :: !(Maybe Int),
    isiSummary :: !(Maybe Text)
  }
  deriving stock (Show, Eq)

-- | A plain outbound image.
imageSeg :: Text -> Segment
imageSeg file = SegImage (ImageSegInfo (Just file) Nothing Nothing)

-- | An outbound custom sticker: same image, flagged @sub_type: 1@ so
-- QQ clients show it as a 表情 rather than a photo.
stickerSeg :: Text -> Segment
stickerSeg file = SegImage (ImageSegInfo (Just file) (Just 1) Nothing)

-- | Did this image arrive as a saved sticker (动画表情)?
isStickerImage :: ImageSegInfo -> Bool
isStickerImage info = info.isiSubType == Just 1

instance FromJSON Segment where
  parseJSON = withObject "Segment" $ \o -> do
    ty <- o .: "type" :: Parser Text
    d <- o .: "data"
    let fallback = pure (SegOther ty (Object d))
        typed = case ty of
          "text" -> SegText <$> d .: "text"
          "at" -> SegAt <$> d .: "qq"
          "reply" -> SegReply <$> d .: "id"
          "image" -> do
            -- Inbound OneBot uses @url@, while our outbound-compatible
            -- 'ToJSON' necessarily writes the same value as @file@. Durable
            -- dispatch persists that encoding and must decode it losslessly.
            url <- do
              nativeUrl <- d .:? "url"
              maybe (d .:? "file") (pure . Just) nativeUrl
            -- NapCat is number/string-inconsistent here too.
            mSub <- d .:? "sub_type"
            subTy <- traverse parseFlexInt mSub
            summ <- d .:? "summary"
            pure (SegImage (ImageSegInfo url subTy summ))
          "json" -> do
            raw <- d .: "data"
            pure $ case parseCard raw of
              Just ci -> SegCard ci
              Nothing -> SegOther "json" (Object d)
          "video" -> do
            file <- d .:? "file" .!= ""
            url <- d .:? "url"
            mSizeV <- d .:? "file_size"
            size <- traverse parseFlexInt64 mSizeV
            pure (SegVideo (VideoSegInfo file url size))
          "face" -> do
            fid <- parseFlexInt =<< d .: "id"
            -- NapCat attaches the whole NTQQ faceElement as data.raw;
            -- faceText is the face's display name with a leading
            -- slash ("/惊讶").
            mRaw <- d .:? "raw"
            name <- case mRaw of
              Nothing -> pure Nothing
              Just raw -> raw .:? "faceText"
            pure (SegFace fid (cleanFaceText =<< name))
          "file" -> SegFile <$> parseFileSeg d
          _ -> fallback
    typed <|> fallback

-- | Parse the @data@ object of a @file@ segment.  NapCat names the
-- internal id @file_id@ on the way in (and @file@ as the display name);
-- some upstream OneBot impls flip these.  We accept either, preferring
-- the more specific @file_id@.
parseFileSeg :: Object -> Parser FileSegInfo
parseFileSeg d = do
  mFid <- d .:? "file_id"
  mFile <- d .:? "file"
  fid <- case mFid <|> mFile of
    Just t -> pure t
    Nothing -> fail "file segment missing both file_id and file"
  let name = case (mFile, mFid) of
        (Just n, _) -> n
        (_, Just n) -> n
        _ -> ""
  -- NapCat ships 'file_size' as a *string* like "2188038", not a
  -- number — same flexibility we already needed for face ids.
  mSizeV <- d .:? "file_size"
  size <- traverse parseFlexInt64 mSizeV
  url <- d .:? "url"
  pure
    FileSegInfo
      { fsiFileId = fid,
        fsiName = name,
        fsiSize = size,
        fsiUrl = url
      }

-- | Drop adjacent duplicates (a B站 card often has tag == title).
dedupAdjacent :: [Text] -> [Text]
dedupAdjacent (a : b : rest)
  | a == b = dedupAdjacent (a : rest)
  | otherwise = a : dedupAdjacent (b : rest)
dedupAdjacent xs = xs

-- | Parse the inner JSON string of a lightapp card.  We require a
-- top-level @app@ id and at least one meta entry carrying a title or
-- description; anything else stays 'SegOther' (real payloads we don't
-- understand should keep their raw shape for later inspection).
parseCard :: Text -> Maybe CardInfo
parseCard raw = do
  Object top <- decodeStrict' (TE.encodeUtf8 raw)
  String app <- KM.lookup "app" top
  metas <- case KM.lookup "meta" top of
    Just (Object m) -> Just [mv | (_, Object mv) <- KM.toList m]
    _ -> Nothing
  -- Pick the meta entry with the most extractable content.
  let scored = [(cardFields mv, mv) | mv <- metas]
      best = case sortOn (negate . fst) scored of
        ((score, mv) : _) | score > 0 -> Just mv
        _ -> Nothing
  mv <- best
  pure
    CardInfo
      { ciApp = app,
        ciTag = str "tag" mv,
        ciTitle = str "title" mv,
        ciDesc = str "desc" mv,
        ciUrl = asum [str k mv | k <- ["qqdocurl", "jumpUrl", "musicUrl", "webUrl", "doc_url"]],
        ciPreview = str "preview" mv,
        ciRaw = raw
      }
  where
    str k o = case KM.lookup k o of
      Just (String s) | not (T.null (T.strip s)) -> Just (T.strip s)
      _ -> Nothing
    cardFields o =
      length (filter (isJust . (`str` o)) ["title", "desc", "jumpUrl", "qqdocurl"]) :: Int

-- | Normalise NapCat's @faceText@ into a display name: drop the
-- conventional leading slash ("/惊讶" → "惊讶") and surrounding
-- whitespace; a blank result means no usable name.
cleanFaceText :: Text -> Maybe Text
cleanFaceText t =
  let t' = T.strip (T.dropWhile (== '/') (T.strip t))
   in if T.null t' then Nothing else Just t'

-- | Accept either a JSON number or a decimal string and decode it as 'Int'.
-- NapCat is inconsistent: e.g. face segments arrive with @id@ as a string
-- like @"264"@ even though OneBot 11 reference docs show a number.
parseFlexInt :: Value -> Parser Int
parseFlexInt = \case
  Number n -> case floatingOrInteger n of
    Right (i :: Integer)
      | i >= fromIntegral (minBound :: Int) && i <= fromIntegral (maxBound :: Int) ->
          pure (fromInteger i)
      | otherwise -> fail "Int out of range"
    Left (_ :: Double) -> fail "expected integer, got float"
  String s -> case TR.signed TR.decimal s of
    Right (i, "") -> pure i
    _ -> fail "string is not a decimal integer"
  v -> typeMismatch "Int" v

-- | Same as 'parseFlexInt' but for 'Int64' — used for fields that
-- can plausibly overflow 'Int' on 32-bit (file sizes, message ids).
parseFlexInt64 :: Value -> Parser Int64
parseFlexInt64 = \case
  Number n -> case floatingOrInteger n of
    Right (i :: Integer)
      | i >= fromIntegral (minBound :: Int64) && i <= fromIntegral (maxBound :: Int64) ->
          pure (fromInteger i)
      | otherwise -> fail "Int64 out of range"
    Left (_ :: Double) -> fail "expected integer, got float"
  String s -> case TR.signed TR.decimal s of
    Right (i, "") -> pure i
    _ -> fail "string is not a decimal integer"
  v -> typeMismatch "Int64" v

instance ToJSON Segment where
  toJSON = \case
    SegText t ->
      object ["type" .= ("text" :: Text), "data" .= object ["text" .= t]]
    SegAt (UserId u) ->
      -- Emit qq as a string: OneBot 11 spec says string here, and NapCat in
      -- particular truncates numeric input through Int32, mangling any QQ
      -- number > 2_147_483_647.
      object
        [ "type" .= ("at" :: Text),
          "data" .= object ["qq" .= T.pack (show u)]
        ]
    SegReply (MessageId m) ->
      object
        [ "type" .= ("reply" :: Text),
          "data" .= object ["id" .= T.pack (show m)]
        ]
    SegImage info ->
      object
        [ "type" .= ("image" :: Text),
          "data"
            .= object
              ( ["file" .= info.isiUrl]
                  <> ["sub_type" .= st | Just st <- [info.isiSubType]]
                  <> ["summary" .= s | Just s <- [info.isiSummary]]
              )
        ]
    SegFace i _ ->
      object ["type" .= ("face" :: Text), "data" .= object ["id" .= i]]
    SegFile fs ->
      object
        [ "type" .= ("file" :: Text),
          "data"
            .= object
              [ "file_id" .= fs.fsiFileId,
                "file" .= fs.fsiName,
                "file_size" .= fs.fsiSize,
                "url" .= fs.fsiUrl
              ]
        ]
    SegVideo v ->
      object
        [ "type" .= ("video" :: Text),
          "data"
            .= object
              ( ["file" .= v.vsiFile]
                  <> ["url" .= u | Just u <- [v.vsiUrl]]
                  <> ["file_size" .= s | Just s <- [v.vsiSize]]
              )
        ]
    SegCard ci ->
      object ["type" .= ("json" :: Text), "data" .= object ["data" .= ci.ciRaw]]
    SegOther t v ->
      object ["type" .= t, "data" .= v]

renderPlainText :: [Segment] -> Text
renderPlainText = T.concat . map go
  where
    go = \case
      SegText t -> t
      SegAt (UserId u) -> "[@#" <> T.pack (show u) <> "] "
      SegReply _ -> ""
      SegImage info
        | isStickerImage info -> "[sticker]"
        | otherwise -> "[image]"
      SegFace i mName ->
        "[face#"
          <> T.pack (show i)
          <> maybe "" (": " <>) mName
          <> "]"
      SegFile fs -> "[file:" <> fs.fsiName <> "]"
      SegVideo _ -> "[video]"
      SegCard ci ->
        -- Compact one-liner: source | title | desc | url, deduped and
        -- capped so a wordy card can't eat a history line.
        let parts =
              dedupAdjacent $
                catMaybes [ci.ciTag, ci.ciTitle, T.take 80 <$> ci.ciDesc, ci.ciUrl]
         in "[card: " <> T.intercalate " | " parts <> "]"
      SegOther t _ -> "[" <> t <> "]"

-- | Trim whitespace at the outer edges of a segment list.
--
-- Removing a placeholder leaves a seam: @"[reply#id] 说得对"@ becomes a
-- text segment starting with a space once the quote token is gone.
-- An edge segment that was nothing but whitespace disappears entirely.
--
-- Shared because both outbound paths need it and only one used to have
-- it — the narration path leaked a leading space for exactly as long as
-- it had its own copy of "turn model text into segments".
trimEdgeSegs :: [Segment] -> [Segment]
trimEdgeSegs segs =
  let start = case segs of
        (SegText x : rest) ->
          let x' = T.stripStart x
           in if T.null x' then rest else SegText x' : rest
        _ -> segs
   in case unsnoc start of
        Just (rest, SegText x) ->
          let x' = T.stripEnd x
           in if T.null x' then rest else rest <> [SegText x']
        _ -> start
