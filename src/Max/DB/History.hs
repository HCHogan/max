module Max.DB.History
  ( HistoryItem (..),
    fetchRecentInGroup,
    fetchMessage,
    fetchMentionHistory,
    fetchMessagesByIds,
  )
where

import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime)
import Database.PostgreSQL.Simple (FromRow, In (..), Only (..), (:.) (..))
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
-- *excluding* @excludeId@.  When @since@ is @Just@, also filters out
-- anything older than that timestamp (used by @!clear@'s watermark).
-- Returned chronological (oldest first).
fetchRecentInGroup ::
  (WithConnection :> es, IOE :> es) =>
  Int64 -> -- group id
  Int64 -> -- message id to exclude (usually the triggering @bot message)
  Maybe UTCTime -> -- only include messages strictly newer than this
  Int -> -- how many
  Eff es [HistoryItem]
fetchRecentInGroup gid excludeId since n = do
  rows <- case since of
    Nothing ->
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
    Just t ->
      query
        "SELECT message_id, user_id, self_id, sender_nickname, rendered_text, received_at \
        \  FROM messages \
        \  WHERE group_id = ? \
        \    AND message_id <> ? \
        \    AND forwarded_in_message_id IS NULL \
        \    AND NOT is_synthetic \
        \    AND received_at > ? \
        \  ORDER BY received_at DESC \
        \  LIMIT ?"
        ((gid, excludeId) :. Only t :. Only n)
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

-- | Reconstruct the bot's mention-exchange history from the messages
-- table: anything sent BY the bot (@user_id = botSelfId@) plus
-- anything that mentions the bot (rendered text contains
-- @\@<botSelfId>@).  Filtered by @clearedAt@ watermark and excluding
-- the current triggering message.  Returned chronological (oldest
-- first), capped at @n@ rows.
--
-- This replaces 'session.history' (the duplicated in-memory cache):
-- single source of truth lives in @messages@.  @!unclear@ can lift
-- the watermark and the bot remembers everything again.
fetchMentionHistory ::
  (WithConnection :> es, IOE :> es) =>
  Int64 -> -- group id
  Int64 -> -- bot self_id
  Int64 -> -- message id to exclude (the triggering @bot message)
  Maybe UTCTime -> -- cleared_at watermark
  Int -> -- max rows
  Eff es [HistoryItem]
fetchMentionHistory gid botId excludeId since n = do
  let mentionLike = "%@" <> T.pack (show botId) <> "%"
  rows <- case since of
    Nothing ->
      query
        "SELECT message_id, user_id, self_id, sender_nickname, rendered_text, received_at \
        \  FROM messages \
        \  WHERE group_id = ? \
        \    AND message_id <> ? \
        \    AND NOT is_synthetic \
        \    AND forwarded_in_message_id IS NULL \
        \    AND (user_id = ? OR rendered_text LIKE ?) \
        \  ORDER BY received_at DESC \
        \  LIMIT ?"
        ((gid, excludeId, botId) :. (mentionLike :: Text, n))
    Just t ->
      query
        "SELECT message_id, user_id, self_id, sender_nickname, rendered_text, received_at \
        \  FROM messages \
        \  WHERE group_id = ? \
        \    AND message_id <> ? \
        \    AND NOT is_synthetic \
        \    AND forwarded_in_message_id IS NULL \
        \    AND received_at > ? \
        \    AND (user_id = ? OR rendered_text LIKE ?) \
        \  ORDER BY received_at DESC \
        \  LIMIT ?"
        ((gid, excludeId) :. (t, botId, mentionLike :: Text, n))
  pure (reverse (rows :: [HistoryItem]))

-- | Bulk fetch by message id.  Preserves the order of input ids
-- (which is what !pin expects — display the user's chosen order).
fetchMessagesByIds ::
  (WithConnection :> es, IOE :> es) =>
  [Int64] ->
  Eff es [HistoryItem]
fetchMessagesByIds [] = pure []
fetchMessagesByIds ids = do
  rows <-
    query
      "SELECT message_id, user_id, self_id, sender_nickname, rendered_text, received_at \
      \  FROM messages \
      \  WHERE message_id IN ?"
      (Only (In ids))
  -- Re-order to match input.
  let byId = [(r.messageId, r) | r <- rows :: [HistoryItem]]
  pure [r | i <- ids, Just r <- [lookup i byId]]
