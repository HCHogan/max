-- | Stored-media metadata exposed to conversation readers. No blob paths or IO.
module Max.Media.Types (StoredImage (..), StoredVideo (..), MediaSegment (..), MessageMedia (..), noMessageMedia) where

import Data.Text (Text)
import Database.PostgreSQL.Simple.FromRow (FromRow (..), field)

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
