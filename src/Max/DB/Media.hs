-- | Model-authored media handles must use these conversation-scoped joins.
-- Handles name @(canonical_message_id, seg_index)@; omitting the segment selects
-- the whole message (ADR 004). Blob workers separately use trusted queue IDs.
module Max.DB.Media
  ( StoredImage (..),
    StoredVideo (..),
    MediaSegment (..),
    MessageMedia (..),
    noMessageMedia,
    fetchMessageImagesInScope,
    fetchMessageVideoInScope,
    fetchMediaSegments,
    ChatMediaRow (..),
    fetchConversationImagesInScope,
    fetchConversationVideosInScope,
    viewableImageMime,
    videoMime,
  )
where

import Data.Int (Int64)
import Data.Map.Merge.Strict qualified as Map
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (listToMaybe)
import Data.Text (Text)
import Database.PostgreSQL.Simple (In (..), Only (..))
import Database.PostgreSQL.Simple.FromRow (FromRow (..), field)
import Effectful
import Effectful.PostgreSQL (WithConnection, query)
import Max.ConversationScope (ConversationScope, conversationStorageId)
import Max.Media.Types

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

-- | Addressable media in message/segment order. Exclude stickers because
-- their captions already replace their markers. Pair remaining bare markers
-- positionally; missing media rows leave their markers unresolved.
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

-- | One stored image or video of a conversation, for its sandbox view.
data ChatMediaRow = ChatMediaRow
  { cmrMessageId :: !Int64,
    cmrSegment :: !Int,
    cmrMime :: !Text,
    cmrSha256 :: !Text
  }
  deriving stock (Show, Eq)

instance FromRow ChatMediaRow where
  fromRow = ChatMediaRow <$> field <*> field <*> field <*> field

-- | Every stored image of this conversation. Stickers are reactions rather
-- than material, so they stay out of the view.
fetchConversationImagesInScope :: (WithConnection :> es, IOE :> es) => ConversationScope -> Eff es [ChatMediaRow]
fetchConversationImagesInScope scope =
  query
    "SELECT mi.canonical_message_id, mi.seg_index, i.mime_type, i.sha256 \
    \  FROM messages m \
    \  JOIN message_images mi USING (canonical_message_id) \
    \  JOIN images i ON i.sha256 = mi.sha256 \
    \  WHERE m.group_id = ? \
    \    AND NOT EXISTS (SELECT 1 FROM stickers s WHERE s.sha256 = mi.sha256)"
    (Only (conversationStorageId scope))

-- | Every stored video of this conversation.
fetchConversationVideosInScope :: (WithConnection :> es, IOE :> es) => ConversationScope -> Eff es [ChatMediaRow]
fetchConversationVideosInScope scope =
  query
    "SELECT mv.canonical_message_id, mv.seg_index, v.mime_type, v.sha256 \
    \  FROM messages m \
    \  JOIN message_videos mv USING (canonical_message_id) \
    \  JOIN videos v ON v.sha256 = mv.sha256 \
    \  WHERE m.group_id = ?"
    (Only (conversationStorageId scope))

-- | The recorded type of an image that belongs in sandbox views, by the same
-- rule as 'fetchConversationImagesInScope': 'Nothing' for stickers.
viewableImageMime :: (WithConnection :> es, IOE :> es) => Text -> Eff es (Maybe Text)
viewableImageMime sha =
  listToMaybe . map fromOnly
    <$> query
      "SELECT mime_type FROM images i \
      \ WHERE sha256 = ? AND NOT EXISTS (SELECT 1 FROM stickers s WHERE s.sha256 = i.sha256)"
      (Only sha)

videoMime :: (WithConnection :> es, IOE :> es) => Text -> Eff es (Maybe Text)
videoMime sha = listToMaybe . map fromOnly <$> query "SELECT mime_type FROM videos WHERE sha256 = ?" (Only sha)
