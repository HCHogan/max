{-# LANGUAGE TypeFamilies #-}

-- | Stored assets belonging to a single bound conversation. Results carry
-- content references, never connections or resolved filesystem paths.
-- Chat files reach tools through the sandbox's /chat mirror instead.
module Max.Effects.MediaQuery (MediaQuery, readImages, readVideo, runMediaQuery) where

import Data.Int (Int64)
import Effectful
import Effectful.Dispatch.Dynamic (interpret, send)
import Effectful.PostgreSQL (WithConnection)
import Max.ConversationScope (ConversationScope)
import Max.DB.History qualified as History
import Max.DB.Media qualified as Media
import Max.DB.Transaction (withReadSnapshot)
import Max.History.Types (HistoryItem)
import Max.Media.Types (StoredImage, StoredVideo)

data MediaQuery :: Effect where
  ReadImages :: Int64 -> Maybe Int -> MediaQuery m (Maybe HistoryItem, [StoredImage])
  ReadVideo :: Int64 -> Maybe Int -> MediaQuery m (Maybe StoredVideo)

type instance DispatchOf MediaQuery = Dynamic

readImages :: (MediaQuery :> es) => Int64 -> Maybe Int -> Eff es (Maybe HistoryItem, [StoredImage])
readImages message segment = send (ReadImages message segment)

readVideo :: (MediaQuery :> es) => Int64 -> Maybe Int -> Eff es (Maybe StoredVideo)
readVideo message segment = send (ReadVideo message segment)

runMediaQuery :: (WithConnection :> es, IOE :> es) => ConversationScope -> Eff (MediaQuery : es) a -> Eff es a
runMediaQuery scope = interpret $ \_ -> \case
  ReadImages message segment ->
    withReadSnapshot $
      (,) <$> History.fetchMessageInScope scope message <*> Media.fetchMessageImagesInScope scope message segment
  ReadVideo message segment -> Media.fetchMessageVideoInScope scope message segment
