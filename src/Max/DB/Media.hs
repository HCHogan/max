-- | Conversation-scoped lookup of media attached to persisted messages.
-- Blob workers may write by their trusted queue ids, but anything reachable
-- from a model-authored handle must pass through these joins.
--
-- ADR 004: media is addressed by @(canonical_message_id, seg_index)@ — the
-- primary key of @message_images@ / @message_videos@, and exactly what the
-- model reads as @[image#\<id\>.\<seg\>]@.  A 'Nothing' segment means the
-- whole message, which is what the bare handle has always meant.
module Max.DB.Media
  ( StoredImage (..),
    StoredVideo (..),
    MediaSegment (..),
    MessageMedia (..),
    noMessageMedia,
    fetchMessageImagesInScope,
    fetchMessageVideoInScope,
    fetchMediaSegments,
  )
where

import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Map.Merge.Strict qualified as Map
import Data.Map.Strict qualified as Map
import Data.Maybe (listToMaybe)
import Data.Text (Text)
import Database.PostgreSQL.Simple (In (..), Only (..))
import Database.PostgreSQL.Simple.FromRow (FromRow, field, fromRow)
import Effectful
import Effectful.PostgreSQL (WithConnection, query)
import Max.ConversationScope (ConversationScope, conversationStorageId)

data StoredImage = StoredImage
  { storedImageSegIndex :: !Int,
    storedImageMime :: !Text,
    storedImageSha256 :: !Text
  }
  deriving stock (Show, Eq)

instance FromRow StoredImage where
  fromRow = StoredImage <$> field <*> field <*> field

data StoredVideo = StoredVideo
  { storedVideoSegIndex :: !Int,
    storedVideoMime :: !Text,
    storedVideoSha256 :: !Text,
    storedVideoDurationSeconds :: !(Maybe Double)
  }
  deriving stock (Show, Eq)

instance FromRow StoredVideo where
  fromRow = StoredVideo <$> field <*> field <*> field <*> field

fetchMessageImagesInScope ::
  (WithConnection :> es, IOE :> es) =>
  ConversationScope ->
  Int64 -> -- canonical message id
  Maybe Int -> -- one seg_index, or every image on the message
  Eff es [StoredImage]
fetchMessageImagesInScope scope canonical seg =
  query
    "SELECT mi.seg_index, i.mime_type, i.sha256 \
    \  FROM message_images mi \
    \  JOIN images i ON i.sha256 = mi.sha256 \
    \  JOIN messages m USING (canonical_message_id) \
    \  WHERE m.group_id = ? AND mi.canonical_message_id = ? \
    \    AND (?::int IS NULL OR mi.seg_index = ?) \
    \  ORDER BY mi.seg_index"
    (conversationStorageId scope, canonical, seg, seg)

fetchMessageVideoInScope ::
  (WithConnection :> es, IOE :> es) =>
  ConversationScope ->
  Int64 -> -- canonical message id
  Maybe Int -> -- one seg_index, or the message's first video
  Eff es (Maybe StoredVideo)
fetchMessageVideoInScope scope canonical seg = do
  rows <-
    query
      "SELECT mv.seg_index, v.mime_type, v.sha256, v.duration_seconds \
      \  FROM message_videos mv \
      \  JOIN videos v USING (sha256) \
      \  JOIN messages m USING (canonical_message_id) \
      \  WHERE m.group_id = ? AND mv.canonical_message_id = ? \
      \    AND (?::int IS NULL OR mv.seg_index = ?) \
      \  ORDER BY mv.seg_index \
      \  LIMIT 1"
      (conversationStorageId scope, canonical, seg, seg)
  pure (listToMaybe rows)

-- | One addressable picture or clip on a message: its @seg_index@, and what
-- the captioner has said about it so far.
data MediaSegment = MediaSegment
  { msSegIndex :: !Int,
    msDescription :: !(Maybe Text),
    msDurationSeconds :: !(Maybe Double)
  }
  deriving stock (Show, Eq)

-- | A message's media, in @seg_index@ order — the order its markers appear
-- in @rendered_text@, because both come from the canonical node list.
data MessageMedia = MessageMedia
  { mmImages :: ![MediaSegment],
    mmVideos :: ![MediaSegment]
  }
  deriving stock (Show, Eq)

noMessageMedia :: MessageMedia
noMessageMedia = MessageMedia {mmImages = [], mmVideos = []}

-- | Every addressable picture and clip on the given messages.
--
-- Stickers are excluded from the image list: their markers are substituted
-- with captions before media handles are tagged, so counting them here would
-- offset every later handle by one.
--
-- This is what turns the bare @[image]@ markers stored in @rendered_text@
-- into the @[image#\<id\>.\<seg\>]@ handles ADR 004 hands the model.  The
-- markers cannot carry the id at write time — it is assigned by the insert
-- that stores the text — so the pairing is positional, and a message whose
-- download failed simply has fewer segments than markers and keeps the bare
-- marker for the tail.  That is the honest answer: an image with no row is
-- one @view_image@ could not return either.
fetchMediaSegments ::
  (WithConnection :> es, IOE :> es) =>
  [Int64] ->
  Eff es (Map Int64 MessageMedia)
fetchMediaSegments [] = pure Map.empty
fetchMediaSegments ids = do
  images <-
    query
      "SELECT mi.canonical_message_id, mi.seg_index, i.description \
      \  FROM message_images mi \
      \  JOIN images i USING (sha256) \
      \  WHERE mi.canonical_message_id IN ? \
      \    AND NOT EXISTS (SELECT 1 FROM stickers s WHERE s.sha256 = mi.sha256) \
      \  ORDER BY mi.canonical_message_id, mi.seg_index"
      (Only (In ids))
  videos <-
    query
      "SELECT mv.canonical_message_id, mv.seg_index, v.description, v.duration_seconds \
      \  FROM message_videos mv \
      \  JOIN videos v USING (sha256) \
      \  WHERE mv.canonical_message_id IN ? \
      \  ORDER BY mv.canonical_message_id, mv.seg_index"
      (Only (In ids))
  let imageMap =
        Map.fromListWith
          (flip (<>))
          [ (canonical, [MediaSegment seg description Nothing])
          | (canonical, seg, description) <- images :: [(Int64, Int, Maybe Text)]
          ]
      videoMap =
        Map.fromListWith
          (flip (<>))
          [ (canonical, [MediaSegment seg description duration])
          | (canonical, seg, description, duration) <- videos :: [(Int64, Int, Maybe Text, Maybe Double)]
          ]
  pure $
    Map.merge
      (Map.mapMissing (\_ segs -> noMessageMedia {mmImages = segs}))
      (Map.mapMissing (\_ segs -> noMessageMedia {mmVideos = segs}))
      (Map.zipWithMatched (\_ imageSegs videoSegs -> MessageMedia imageSegs videoSegs))
      imageMap
      videoMap
