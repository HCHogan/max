module OneBot.Segment
  ( Segment (..),
    FileSegInfo (..),
    ImageSegInfo (..),
    imageSeg,
    stickerSeg,
    isStickerImage,
    renderPlainText,
    segmentMentions,
    mentionsUser,
  )
where

import Control.Applicative ((<|>))
import Data.Aeson
import Data.Aeson.Types (Parser, typeMismatch)
import Data.Char (isAlphaNum, isAscii, isDigit)
import Data.Int (Int64)
import Data.Maybe (fromMaybe)
import Data.Scientific (floatingOrInteger)
import Data.Text (Text)
import Data.Text qualified as T
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
  | SegFace !Int
  | -- | Non-image file attached to a group message.  @data.file_id@ is
    -- the only thing guaranteed to round-trip back to QQ; @data.url@ is
    -- best-effort (sometimes inlined by NapCat, sometimes needs a
    -- separate @get_group_file_url@ call).
    SegFile !FileSegInfo
  | SegOther !Text !Value
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
            url <- d .:? "url"
            -- NapCat is number/string-inconsistent here too.
            mSub <- d .:? "sub_type"
            subTy <- traverse parseFlexInt mSub
            summ <- d .:? "summary"
            pure (SegImage (ImageSegInfo url subTy summ))
          "face" -> SegFace <$> (parseFlexInt =<< d .: "id")
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
        [ "type" .= ("at" :: Text)
        , "data" .= object ["qq" .= T.pack (show u)]
        ]
    SegReply (MessageId m) ->
      object
        [ "type" .= ("reply" :: Text)
        , "data" .= object ["id" .= T.pack (show m)]
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
    SegFace i ->
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
    SegOther t v ->
      object ["type" .= t, "data" .= v]

renderPlainText :: [Segment] -> Text
renderPlainText = T.concat . map go
  where
    go = \case
      SegText t -> t
      SegAt (UserId u) -> "@" <> T.pack (show u) <> " "
      SegReply _ -> ""
      SegImage info
        | isStickerImage info -> "[动画表情]"
        | otherwise -> "[image]"
      SegFace _ -> "[face]"
      SegFile fs -> "[file:" <> fs.fsiName <> "]"
      SegOther t _ -> "[" <> t <> "]"

-- | Parse LLM-authored reply text into segments, converting raw
-- @\@\<QQ号\>@ spans into structural 'SegAt's — the outbound inverse
-- of 'renderPlainText', which is exactly the shape the model sees
-- inbound mentions in.  A span converts only when it reads as a
-- standalone mention — 5 to 11 digits, not glued to an ASCII word
-- character on either side (so emails and identifiers pass through;
-- CJK neighbours are fine) — AND @known@ accepts the id.  Callers
-- pass a membership check (typically against the group's member
-- list), which keeps hallucinated numbers and non-members as plain
-- text; pass @const True@ to convert on syntax alone.  One space
-- after a converted mention is swallowed: 'renderPlainText' adds it
-- back, so persisted history round-trips without growing padding.
segmentMentions :: (UserId -> Bool) -> Text -> [Segment]
segmentMentions known = go
  where
    go t = case T.breakOn "@" t of
      (before, rest)
        | T.null rest -> [SegText before | not (T.null before)]
        | otherwise ->
            let cand = T.drop 1 rest -- past the @
                digits = T.takeWhile isDigit cand
                after = T.drop (T.length digits) cand
                n = T.length digits
                asciiWord c = isAscii c && isAlphaNum c
                okBefore = maybe True (not . asciiWord . snd) (T.unsnoc before)
                okAfter = maybe True (not . asciiWord . fst) (T.uncons after)
                uid = UserId (either (const 0) fst (TR.decimal digits))
             in if n >= 5 && n <= 11 && okBefore && okAfter && known uid
                  then
                    [SegText before | not (T.null before)]
                      <> (SegAt uid : go (fromMaybe after (T.stripPrefix " " after)))
                  else case go cand of
                    -- Not a mention: keep the literal @ and fold it
                    -- into the following text run.
                    SegText t' : segs -> SegText (before <> "@" <> t') : segs
                    segs -> SegText (before <> "@") : segs

mentionsUser :: UserId -> [Segment] -> Bool
mentionsUser uid = any $ \case
  SegAt u -> u == uid
  _ -> False
