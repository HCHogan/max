{-# LANGUAGE TypeFamilies #-}

-- | Stored assets belonging to a single bound conversation. Results carry
-- content references, never connections or resolved filesystem paths.
module Max.Effects.MediaQuery (MediaQuery, readImages, readVideo, readStoredFile, listFiles, runMediaQuery) where

import Data.Int (Int64)
import Data.Text (Text)
import Effectful
import Effectful.Dispatch.Dynamic (interpret, send)
import Effectful.PostgreSQL (WithConnection)
import Max.ConversationScope (ConversationScope, conversationStorageId)
import Max.DB.Files qualified as Files
import Max.DB.History qualified as History
import Max.DB.Media qualified as Media
import Max.DB.Transaction (withReadSnapshot)
import Max.File.Types (FileRecord)
import Max.History.Types (HistoryItem)
import Max.Media.Types (StoredImage, StoredVideo)

data MediaQuery :: Effect where
  ReadImages :: Int64 -> Maybe Int -> MediaQuery m (Maybe HistoryItem, [StoredImage])
  ReadVideo :: Int64 -> Maybe Int -> MediaQuery m (Maybe StoredVideo)
  ReadFile :: Text -> MediaQuery m (Maybe FileRecord)
  ListFiles :: Int -> MediaQuery m [FileRecord]

type instance DispatchOf MediaQuery = Dynamic

readImages :: (MediaQuery :> es) => Int64 -> Maybe Int -> Eff es (Maybe HistoryItem, [StoredImage])
readImages message segment = send (ReadImages message segment)

readVideo :: (MediaQuery :> es) => Int64 -> Maybe Int -> Eff es (Maybe StoredVideo)
readVideo message segment = send (ReadVideo message segment)

readStoredFile :: (MediaQuery :> es) => Text -> Eff es (Maybe FileRecord)
readStoredFile = send . ReadFile

listFiles :: (MediaQuery :> es) => Int -> Eff es [FileRecord]
listFiles = send . ListFiles

runMediaQuery :: (WithConnection :> es, IOE :> es) => ConversationScope -> Eff (MediaQuery : es) a -> Eff es a
runMediaQuery scope = interpret $ \_ -> \case
  ReadImages message segment ->
    withReadSnapshot $
      (,) <$> History.fetchMessageInScope scope message <*> Media.fetchMessageImagesInScope scope message segment
  ReadVideo message segment -> Media.fetchMessageVideoInScope scope message segment
  ReadFile identifier -> Files.fetchByFileIdInScope scope identifier
  ListFiles limit -> Files.listRecentInGroup (conversationStorageId scope) (max 1 (min 50 limit))
