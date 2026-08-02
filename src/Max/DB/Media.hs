-- | Conversation-scoped lookup of media attached to persisted messages.
-- Blob workers may write by their trusted queue ids, but anything reachable
-- from a model-authored message id must pass through these joins.
module Max.DB.Media
  ( StoredImage (..),
    StoredVideo (..),
    fetchMessageImagesInScope,
    fetchMessageVideoInScope,
  )
where

import Data.Int (Int64)
import Data.Maybe (listToMaybe)
import Data.Text (Text)
import Database.PostgreSQL.Simple.FromRow (FromRow, field, fromRow)
import Effectful
import Effectful.PostgreSQL (WithConnection, query)
import Max.ConversationScope (ConversationScope, conversationStorageId)

data StoredImage = StoredImage
  { storedImageMime :: !Text,
    storedImageSha256 :: !Text
  }
  deriving stock (Show, Eq)

instance FromRow StoredImage where
  fromRow = StoredImage <$> field <*> field

data StoredVideo = StoredVideo
  { storedVideoMime :: !Text,
    storedVideoSha256 :: !Text,
    storedVideoDurationSeconds :: !(Maybe Double)
  }
  deriving stock (Show, Eq)

instance FromRow StoredVideo where
  fromRow = StoredVideo <$> field <*> field <*> field

fetchMessageImagesInScope ::
  (WithConnection :> es, IOE :> es) =>
  ConversationScope ->
  Int64 ->
  Eff es [StoredImage]
fetchMessageImagesInScope scope mid =
  query
    "SELECT i.mime_type, i.sha256 \
    \  FROM message_images mi \
    \  JOIN images i ON i.sha256 = mi.sha256 \
    \  JOIN messages m ON m.message_id = mi.message_id \
    \  WHERE m.group_id = ? AND mi.message_id = ? \
    \  ORDER BY mi.seg_index"
    (conversationStorageId scope, mid)

fetchMessageVideoInScope ::
  (WithConnection :> es, IOE :> es) =>
  ConversationScope ->
  Int64 ->
  Eff es (Maybe StoredVideo)
fetchMessageVideoInScope scope mid = do
  rows <-
    query
      "SELECT v.mime_type, v.sha256, v.duration_seconds \
      \  FROM message_videos mv \
      \  JOIN videos v USING (sha256) \
      \  JOIN messages m ON m.message_id = mv.message_id \
      \  WHERE m.group_id = ? AND mv.message_id = ? \
      \  ORDER BY mv.seg_index \
      \  LIMIT 1"
      (conversationStorageId scope, mid)
  pure (listToMaybe rows)
