module Max.DB.History
  ( HistoryItem (..),
    fetchRecentInGroup,
    fetchMessage,
  )
where

import Data.Int (Int64)
import Data.Text (Text)
import Data.Time (UTCTime)
import Database.PostgreSQL.Simple (FromRow)
import Database.PostgreSQL.Simple.FromRow (field, fromRow)
import Effectful
import Effectful.PostgreSQL (WithConnection, query)

-- | The fields needed to render a message as a line of prompt context.
data HistoryItem = HistoryItem
  { messageId :: !Int64,
    userId :: !Int64,
    selfId :: !Int64,
    senderNickname :: !(Maybe Text),
    renderedText :: !Text,
    receivedAt :: !UTCTime
  }
  deriving stock (Show)

instance FromRow HistoryItem where
  fromRow =
    HistoryItem
      <$> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field

-- | Last @n@ real (non-synthetic, non-forward-child) messages in @gid@,
-- *excluding* @excludeId@. Returned chronological (oldest first).
fetchRecentInGroup ::
  (WithConnection :> es, IOE :> es) =>
  Int64 -> -- group id
  Int64 -> -- message id to exclude (usually the triggering @bot message)
  Int -> -- how many
  Eff es [HistoryItem]
fetchRecentInGroup gid excludeId n = do
  rows <-
    query
      "SELECT message_id, user_id, self_id, sender_nickname, rendered_text, received_at \
      \  FROM messages \
      \  WHERE group_id = ? \
      \    AND message_id <> ? \
      \    AND forwarded_in_message_id IS NULL \
      \    AND NOT is_synthetic \
      \  ORDER BY received_at DESC \
      \  LIMIT ?"
      (gid, excludeId, n)
  pure (reverse (rows :: [HistoryItem]))

-- | One message by id, real or synthetic.
fetchMessage :: (WithConnection :> es, IOE :> es) => Int64 -> Eff es (Maybe HistoryItem)
fetchMessage mid = do
  rows <-
    query
      "SELECT message_id, user_id, self_id, sender_nickname, rendered_text, received_at \
      \  FROM messages \
      \  WHERE message_id = ? \
      \  LIMIT 1"
      [mid]
  pure $ case rows :: [HistoryItem] of
    (h : _) -> Just h
    [] -> Nothing
