-- | Canonical metadata-to-context handles. Rendering is shared and pure.
module Max.Context.Media (tagMediaMarkers, consumeMarkers) where

import Data.Int (Int64)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Max.History.Types (HistoryItem (..))
import Max.Media.Types (MediaSegment (..), MessageMedia (..), noMessageMedia)
import Max.Time (fmtDurationSec)

tshow :: (Show a) => a -> Text
tshow = T.pack . show

-- | Replace forward markers with container IDs and video markers with message/segment
-- handles (ADR 004). Match videos left to right in canonical segment order;
-- keep bare markers when no stored segment is available.
tagMediaMarkers :: Map.Map Int64 MessageMedia -> HistoryItem -> HistoryItem
tagMediaMarkers segments h =
  h {renderedText = tagVideos (T.replace "[forward]" forwardHandle h.renderedText)}
  where
    forwardHandle = "[forward#" <> tshow h.canonicalId <> "]"
    media = Map.findWithDefault noMessageMedia h.canonicalId segments
    tagVideos = consumeMarkers "[video]" (mmVideos media) videoHandle
    videoHandle seg =
      "[video#"
        <> tshow h.canonicalId
        <> "."
        <> tshow seg.msSegIndex
        <> maybe "" (\d -> ": " <> T.take 120 d) seg.msDescription
        <> "]"
        <> maybe "" (\d -> "(" <> fmtDurationSec d <> ")") seg.msDurationSeconds

-- | Replace each occurrence of @marker@, left to right, with the handle
-- built from the next media segment; occurrences past the end of the
-- segment list are left alone.
consumeMarkers :: Text -> [MediaSegment] -> (MediaSegment -> Text) -> Text -> Text
consumeMarkers marker = go
  where
    go [] _ t = t
    go (seg : rest) handle t = case T.breakOn marker t of
      (_, "") -> t
      (before, suffix) ->
        before <> handle seg <> go rest handle (T.drop (T.length marker) suffix)
