{-# LANGUAGE TypeFamilies #-}

-- | Conversation reads with scope fixed by host assembly. Media enrichment
-- accepts only rows obtained by the scoped reader, never arbitrary model ids.
module Max.Effects.ConversationQuery (ConversationQuery, readRoster, readMessage, readForward, searchConversation, expandEpisode, runConversationQuery) where

import Control.Monad (forM)
import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Maybe (listToMaybe)
import Data.Text (Text)
import Effectful
import Effectful.Dispatch.Dynamic (interpret, send)
import Effectful.PostgreSQL (WithConnection)
import Max.Conversation.Roster (ConversationRoster)
import Max.ConversationScope (ConversationScope, conversationStorageId, currentConversationRecall)
import Max.DB.History qualified as History
import Max.DB.History.Media (withMediaHandles)
import Max.DB.Media (fetchMediaSegments)
import Max.DB.Transaction (withReadSnapshot)
import Max.Embedding (EmbeddingRecord)
import Max.Episode.Types (EpisodeExpansion (..), EpisodeHandle)
import Max.EpisodeStore qualified as Episodes
import Max.History.Types (HistoryItem (..), LedgerItem (..), MessageCursor)
import Max.Media.Types (MessageMedia)
import Max.Platform.Store (conversationRoster)
import Max.Recall qualified as Recall
import Max.Recall.Types (RecallHit)

data ConversationQuery :: Effect where
  ReadRoster :: ConversationQuery m ConversationRoster
  ReadMessage :: Int64 -> ConversationQuery m (Maybe HistoryItem)
  ReadForward :: Int64 -> Int -> ConversationQuery m [HistoryItem]
  SearchConversation :: Text -> Maybe EmbeddingRecord -> Int -> ConversationQuery m [RecallHit]
  ExpandEpisode :: EpisodeHandle -> Maybe MessageCursor -> Int -> ConversationQuery m (Maybe (EpisodeExpansion, Map Int64 MessageMedia))

type instance DispatchOf ConversationQuery = Dynamic

readRoster :: (ConversationQuery :> es) => Eff es ConversationRoster
readRoster = send ReadRoster

readMessage :: (ConversationQuery :> es) => Int64 -> Eff es (Maybe HistoryItem)
readMessage = send . ReadMessage

readForward :: (ConversationQuery :> es) => Int64 -> Int -> Eff es [HistoryItem]
readForward identifier limit = send (ReadForward identifier limit)

searchConversation :: (ConversationQuery :> es) => Text -> Maybe EmbeddingRecord -> Int -> Eff es [RecallHit]
searchConversation query embedding limit = send (SearchConversation query embedding limit)

expandEpisode :: (ConversationQuery :> es) => EpisodeHandle -> Maybe MessageCursor -> Int -> Eff es (Maybe (EpisodeExpansion, Map Int64 MessageMedia))
expandEpisode handle after limit = send (ExpandEpisode handle after limit)

runConversationQuery :: (WithConnection :> es, IOE :> es) => ConversationScope -> Eff (ConversationQuery : es) a -> Eff es a
runConversationQuery scope = interpret $ \_ -> \case
  ReadRoster -> withReadSnapshot (conversationRoster (conversationStorageId scope))
  ReadMessage identifier -> withReadSnapshot $ do
    message <- History.fetchMessageInScope scope identifier
    listToMaybe <$> withMediaHandles (maybe [] pure message)
  ReadForward identifier limit ->
    withReadSnapshot $
      History.fetchForwardChildrenInScope scope identifier (max 1 (min 100 limit)) >>= withMediaHandles
  SearchConversation query embedding limit -> Recall.searchRecall (currentConversationRecall scope) query embedding limit
  ExpandEpisode handle after limit -> withReadSnapshot $ do
    expanded <- Episodes.expandEpisode (currentConversationRecall scope) handle after limit
    forM expanded $ \episode -> do
      media <- fetchMediaSegments [entry.history.canonicalId | entry <- episode.expansionMessages]
      pure (episode, media)
