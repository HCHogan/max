-- | Cache of provider video renditions ('Max.Media.Rendition').
module Max.DB.VideoRendition
  ( StoredRendition (..),
    fetchVideoRendition,
    storeVideoRendition,
  )
where

import Control.Monad (void)
import Data.Maybe (listToMaybe)
import Data.Text (Text)
import Database.PostgreSQL.Simple.FromRow (FromRow (..), field)
import Effectful
import Effectful.PostgreSQL (WithConnection, execute, query)

data StoredRendition = StoredRendition
  { renditionSha256 :: !Text,
    visionTokens :: !Int,
    sourceSeconds :: !Double,
    startSeconds :: !Double,
    spanSeconds :: !Double,
    speed :: !Double
  }
  deriving stock (Show, Eq)

instance FromRow StoredRendition where
  fromRow = StoredRendition <$> field <*> field <*> field <*> field <*> field <*> field

fetchVideoRendition :: (WithConnection :> es, IOE :> es) => Text -> Text -> Eff es (Maybe StoredRendition)
fetchVideoRendition source params =
  listToMaybe
    <$> query
      "SELECT rendition_sha256, vision_tokens, source_seconds, start_seconds, span_seconds, speed \
      \  FROM video_renditions WHERE source_sha256 = ? AND params = ?"
      (source, params)

storeVideoRendition :: (WithConnection :> es, IOE :> es) => Text -> Text -> StoredRendition -> Eff es ()
storeVideoRendition source params r =
  void $
    execute
      "INSERT INTO video_renditions \
      \  (source_sha256, params, rendition_sha256, vision_tokens, source_seconds, start_seconds, span_seconds, speed) \
      \ VALUES (?,?,?,?,?,?,?,?) ON CONFLICT DO NOTHING"
      (source, params, r.renditionSha256, r.visionTokens, r.sourceSeconds, r.startSeconds, r.spanSeconds, r.speed)
