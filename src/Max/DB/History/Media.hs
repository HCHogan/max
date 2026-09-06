-- | Attach media handles to already scoped conversation rows.
module Max.DB.History.Media (withMediaHandles) where

import Effectful
import Effectful.PostgreSQL (WithConnection)
import Max.Context.Media (tagMediaMarkers)
import Max.DB.Media (fetchMediaSegments)
import Max.History.Types (HistoryItem (..))

-- | 'tagMediaMarkers' for callers holding a handful of rows rather than a
-- whole turn's context: fetch the media segments those rows need, then tag.
-- One query, so a tool returning a forward bundle costs the same as one
-- returning a single message.
withMediaHandles ::
  (WithConnection :> es, IOE :> es) =>
  [HistoryItem] ->
  Eff es [HistoryItem]
withMediaHandles [] = pure []
withMediaHandles items = do
  segments <- fetchMediaSegments (map (.canonicalId) items)
  pure (map (tagMediaMarkers segments) items)
