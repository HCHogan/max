-- |
-- Sticker library persistence: detect sticker segments on the way in
-- and upsert them into @stickers@ (keyed by the image's sha256, so
-- the same sticker reposted anywhere counts up 'times_seen' — repost
-- frequency is the "this one is good" signal for retrieval).
-- Captioning and embedding happen asynchronously (see "Max.Stickers").
module Max.DB.Stickers
  ( StickerMeta (..),
    stickerMeta,
    recordSticker,
  )
where

import Data.Aeson (Value (Object, String))
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.Int (Int64)
import Data.Text (Text)
import Effectful (Eff, IOE, (:>))
import Effectful.PostgreSQL (WithConnection, execute)
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
    look k o = case KM.lookup (K.fromText k) o of
      Just (String s) -> Just s
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
