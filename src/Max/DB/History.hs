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
-- table: anything sent BY the bot (@user_id = botSelfId@), anything
-- that mentions the bot (rendered text contains @\@<botSelfId>@),
-- plus anything that replies to (quotes) a bot message — replying
-- triggers a turn just like a mention, so it must be
-- reconstructable here too.  Filtered by @clearedAt@ watermark and
-- excluding the current triggering message.  Returned chronological
-- (oldest first), capped at @n@ rows.
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
        "SELECT m.message_id, m.user_id, m.self_id, m.sender_nickname, m.rendered_text, m.received_at \
        \  FROM messages m \
        \  WHERE m.group_id = ? \
        \    AND m.message_id <> ? \
        \    AND NOT m.is_synthetic \
        \    AND m.forwarded_in_message_id IS NULL \
        \    AND (m.user_id = ? OR m.rendered_text LIKE ? \
        \         OR EXISTS (SELECT 1 FROM messages b \
        \                     WHERE b.message_id = m.reply_to_message_id \
        \                       AND b.user_id = ?)) \
        \  ORDER BY m.received_at DESC \
        \  LIMIT ?"
        ((gid, excludeId, botId) :. (mentionLike :: Text, botId, n))
    Just t ->
      query
        "SELECT m.message_id, m.user_id, m.self_id, m.sender_nickname, m.rendered_text, m.received_at \
        \  FROM messages m \
        \  WHERE m.group_id = ? \
        \    AND m.message_id <> ? \
        \    AND NOT m.is_synthetic \
        \    AND m.forwarded_in_message_id IS NULL \
        \    AND m.received_at > ? \
        \    AND (m.user_id = ? OR m.rendered_text LIKE ? \
        \         OR EXISTS (SELECT 1 FROM messages b \
        \                     WHERE b.message_id = m.reply_to_message_id \
        \                       AND b.user_id = ?)) \
        \  ORDER BY m.received_at DESC \
        \  LIMIT ?"
        ((gid, excludeId) :. (t, botId, mentionLike :: Text, botId, n))
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
