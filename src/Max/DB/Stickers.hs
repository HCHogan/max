-- |
-- Sticker library persistence: detect sticker segments on the way in
-- and upsert them into @stickers@ (keyed by the image's sha256, so
-- the same sticker reposted anywhere counts up 'times_seen' — repost
-- frequency is the "this one is good" signal for retrieval).
-- Captioning and embedding happen asynchronously (see "Max.Stickers").
module Max.DB.Stickers
  ( StickerMeta (..),
    StickerRow (..),
    StickerStats (..),
    stickerMeta,
    recordSticker,
    stickerStats,
    listRecentStickers,
    setStickerBanned,
    findStickerByCaption,
  )
where

import Data.Aeson
  ( FromJSON (..),
    ToJSON (..),
    Value (Number, Object, String),
    object,
    withObject,
    (.:),
    (.:?),
    (.=),
  )
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.Int (Int64)
import Data.Maybe (listToMaybe)
import Data.Scientific (floatingOrInteger)
import Data.Text (Text)
import Data.Text qualified as T
import Database.PostgreSQL.Simple (Only (..))
import Effectful (Eff, IOE, (:>))
import Effectful.PostgreSQL (WithConnection, execute, query, query_)
import OneBot.Segment (ImageSegInfo (..), Segment (..), isStickerImage)

-- | What we know about a sticker at ingest time, before any vision
-- model has looked at it.
data StickerMeta = StickerMeta
  { smKind :: !Text, -- "custom" | "mface"
    smEmojiId :: !(Maybe Text),
    smPackageId :: !(Maybe Text),
    smKey :: !(Maybe Text),
    smSummary :: !(Maybe Text)
  }
  deriving stock (Show)

-- Rides along inside an 'Max.Images.ImageJob' in @fetch_jobs@, so
-- these values now outlive the process: named fields, and everything
-- optional stays optional on the way back in.
instance ToJSON StickerMeta where
  toJSON m =
    object
      [ "kind" .= m.smKind,
        "emoji_id" .= m.smEmojiId,
        "package_id" .= m.smPackageId,
        "key" .= m.smKey,
        "summary" .= m.smSummary
      ]

instance FromJSON StickerMeta where
  parseJSON = withObject "StickerMeta" $ \o ->
    StickerMeta
      <$> o .: "kind"
      <*> o .:? "emoji_id"
      <*> o .:? "package_id"
      <*> o .:? "key"
      <*> o .:? "summary"

-- | Is this segment a sticker, and if so which kind?  Saved 动画表情
-- arrive as image segments with @sub_type=1@; marketplace 商城表情 as
-- @mface@ segments (kept whole in 'SegOther') whose id/key we need to
-- resend natively.
stickerMeta :: Segment -> Maybe StickerMeta
stickerMeta = \case
  SegImage info
    | isStickerImage info ->
        Just
          StickerMeta
            { smKind = "custom",
              smEmojiId = Nothing,
              smPackageId = Nothing,
              smKey = Nothing,
              smSummary = info.isiSummary
            }
  SegOther "mface" (Object o) ->
    Just
      StickerMeta
        { smKind = "mface",
          smEmojiId = look "emoji_id" o,
          smPackageId = look "emoji_package_id" o,
          smKey = look "key" o,
          smSummary = look "summary" o
        }
  _ -> Nothing
  where
    -- NapCat mixes types here (emoji_package_id is a JSON number,
    -- the rest strings); store everything as text.
    look k o = case KM.lookup (K.fromText k) o of
      Just (String s) -> Just s
      Just (Number n) -> case floatingOrInteger n of
        Right (i :: Integer) -> Just (T.pack (show i))
        Left (_ :: Double) -> Nothing
      _ -> Nothing

-- | Upsert one sighting.  On repeat sightings the counters advance
-- and any metadata we were missing gets filled in (an mface seen
-- first inside a forward may lack fields the direct send carries).
recordSticker ::
  (WithConnection :> es, IOE :> es) =>
  Text -> -- sha256 (images row must exist)
  Maybe Int64 -> -- group it was seen in, if known
  StickerMeta ->
  Eff es ()
recordSticker sha gid meta = do
  _ <-
    execute
      "INSERT INTO stickers \
      \ (sha256, kind, emoji_id, emoji_package_id, mface_key, summary, first_group_id) \
      \ VALUES (?,?,?,?,?,?,?) \
      \ ON CONFLICT (sha256) DO UPDATE SET \
      \   times_seen = stickers.times_seen + 1, \
      \   last_seen_at = now(), \
      \   emoji_id = COALESCE(stickers.emoji_id, EXCLUDED.emoji_id), \
      \   emoji_package_id = COALESCE(stickers.emoji_package_id, EXCLUDED.emoji_package_id), \
      \   mface_key = COALESCE(stickers.mface_key, EXCLUDED.mface_key), \
      \   summary = COALESCE(stickers.summary, EXCLUDED.summary)"
      ( sha,
        meta.smKind,
        meta.smEmojiId,
        meta.smPackageId,
        meta.smKey,
        meta.smSummary,
        gid
      )
  pure ()

--------------------------------------------------------------------------------
-- !sticker command support.

data StickerStats = StickerStats
  { ssTotal :: !Int,
    ssCaptioned :: !Int,
    ssBanned :: !Int,
    ssPending :: !Int
  }
  deriving stock (Show)

stickerStats :: (WithConnection :> es, IOE :> es) => Eff es StickerStats
stickerStats = do
  rows <-
    query_
      "SELECT count(*)::int, count(description)::int, \
      \       (count(*) FILTER (WHERE banned))::int, \
      \       (count(*) FILTER (WHERE description IS NULL AND NOT banned \
      \                           AND caption_attempts < 5))::int \
      \ FROM stickers"
  pure $ case rows of
    [(t, c, b, p)] -> StickerStats t c b p
    _ -> StickerStats 0 0 0 0

data StickerRow = StickerRow
  { srSha :: !Text,
    srKind :: !Text,
    srDescription :: !Text,
    srTimesSeen :: !Int,
    srTimesSent :: !Int
  }
  deriving stock (Show)

-- | Most recently seen captioned stickers — what !sticker list shows
-- (sha prefix is the handle for !sticker ban).
listRecentStickers :: (WithConnection :> es, IOE :> es) => Int -> Eff es [StickerRow]
listRecentStickers n = do
  rows <-
    query
      "SELECT sha256, kind, description, times_seen, times_sent \
      \ FROM stickers WHERE description IS NOT NULL AND NOT banned \
      \ ORDER BY last_seen_at DESC LIMIT ?"
      [n]
  pure [StickerRow sha kind d ts tx | (sha, kind, d, ts, tx) <- rows]

-- | (Un)ban by sha256 prefix; returns how many rows matched.  The
-- caller enforces a minimum prefix length so @!sticker ban a@ can't
-- carpet-bomb the library.
setStickerBanned :: (WithConnection :> es, IOE :> es) => Bool -> Text -> Eff es Int
setStickerBanned b prefix =
  fromIntegral
    <$> execute
      "UPDATE stickers SET banned = ? WHERE sha256 LIKE ?"
      (b, prefix <> "%")

-- | Resolve a caption fragment to a sticker id — the recovery path
-- for a model that wrote @[sticker#柴犬瘫地]@ instead of the number.
-- The display form truncates captions at 80 chars, so an echoed
-- caption is a *prefix* of the stored description; exact and prefix
-- hits outrank substring hits, popularity breaks ties.  LIKE
-- wildcards in model text are escaped, not interpreted.
findStickerByCaption :: (WithConnection :> es, IOE :> es) => Text -> Eff es (Maybe Int64)
findStickerByCaption cap = do
  let esc = T.concatMap (\c -> if c `elem` ("%_\\" :: String) then T.pack ['\\', c] else T.singleton c) cap
  rows <-
    query
      "SELECT s.id FROM stickers s \
      \ WHERE NOT s.banned AND s.description IS NOT NULL \
      \   AND (s.description = ? OR s.description LIKE ? OR s.description LIKE ?) \
      \ ORDER BY (s.description = ?) DESC, (s.description LIKE ?) DESC, s.times_sent DESC, s.id DESC \
      \ LIMIT 1"
      (cap, esc <> "%", "%" <> esc <> "%", cap, esc <> "%")
  pure (fromOnly <$> listToMaybe rows)
