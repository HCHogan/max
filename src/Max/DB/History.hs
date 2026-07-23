module Max.DB.History
  ( HistoryItem (..),
    bestName,
    fetchRecentInGroup,
    fetchMessage,
    fetchMentionHistory,
    fetchMessagesByIds,
    fetchForwardChildren,
  )
where

import Control.Applicative ((<|>))

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
    -- | 群名片 — the sender's per-group display name.  This is what
    -- other members actually see and call them by, so rendering
    -- prefers it over the (global) nickname.
    senderCard :: !(Maybe Text),
    renderedText :: !Text,
    receivedAt :: !UTCTime,
    -- | The message this one quotes (@reply_to_message_id@ column), if
    -- any.  Rendered as a @[↩#\<id\>]@ handle so the model can walk the
    -- quote chain via @get_message_by_id@; 'Nothing' for non-replies.
    replyTo :: !(Maybe Int64)
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
      <*> field
      <*> field

-- | The name group members actually see for this sender: 群名片
-- first, then nickname; 'Nothing' when both are absent/blank (QQ
-- sends @\"\"@ for an unset card, so blanks count as absent).
bestName :: HistoryItem -> Maybe Text
bestName h = nonBlank h.senderCard <|> nonBlank h.senderNickname

nonBlank :: Maybe Text -> Maybe Text
nonBlank (Just t) | not (T.null (T.strip t)) = Just (T.strip t)
nonBlank _ = Nothing

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
        "SELECT message_id, user_id, self_id, sender_nickname, sender_card, rendered_text, received_at, reply_to_message_id \
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
        "SELECT message_id, user_id, self_id, sender_nickname, sender_card, rendered_text, received_at, reply_to_message_id \
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
      "SELECT message_id, user_id, self_id, sender_nickname, sender_card, rendered_text, received_at, reply_to_message_id \
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
-- anything that replies to (quotes) a bot message — replying
-- triggers a turn just like a mention — plus anything the bot itself
-- quoted: proactive (intent-triggered) replies quote their target,
-- and without the user's side of those exchanges the bot reads its
-- own answers with no visible question and repeats itself.  Filtered
-- by @clearedAt@ watermark and excluding the current triggering
-- message.  Returned chronological (oldest first), capped at @n@
-- rows.  Synthetic rows are excluded EXCEPT the bot's own — those
-- are persisted @[silence]@ turns ('Max.DB.Message.insertSilence'),
-- which must show so a declined question doesn't read as pending.
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
  -- Rendered mentions of the bot come in two shapes: the canonical
  -- "[@#<id>]" token (current renderer) and the legacy bare "@<id>"
  -- (old rows).  "%@<id>%" matches the legacy form only — the token
  -- has '#' between '@' and the digits — so both patterns go into
  -- the query.
  let mentionLike = "%@" <> T.pack (show botId) <> "%"
      mentionTokLike = "%[@#" <> T.pack (show botId) <> "]%"
  rows <- case since of
    Nothing ->
      query
        "SELECT m.message_id, m.user_id, m.self_id, m.sender_nickname, m.sender_card, m.rendered_text, m.received_at, m.reply_to_message_id \
        \  FROM messages m \
        \  WHERE m.group_id = ? \
        \    AND m.message_id <> ? \
        \    AND (NOT m.is_synthetic OR m.user_id = ?) \
        \    AND m.forwarded_in_message_id IS NULL \
        \    AND (m.user_id = ? OR m.rendered_text LIKE ? OR m.rendered_text LIKE ? \
        \         OR EXISTS (SELECT 1 FROM messages b \
        \                     WHERE b.message_id = m.reply_to_message_id \
        \                       AND b.user_id = ?) \
        \         OR EXISTS (SELECT 1 FROM messages r \
        \                     WHERE r.reply_to_message_id = m.message_id \
        \                       AND r.user_id = ?)) \
        \  ORDER BY m.received_at DESC \
        \  LIMIT ?"
        ((gid, excludeId, botId, botId) :. (mentionLike :: Text, mentionTokLike, botId, botId, n))
    Just t ->
      query
        "SELECT m.message_id, m.user_id, m.self_id, m.sender_nickname, m.sender_card, m.rendered_text, m.received_at, m.reply_to_message_id \
        \  FROM messages m \
        \  WHERE m.group_id = ? \
        \    AND m.message_id <> ? \
        \    AND (NOT m.is_synthetic OR m.user_id = ?) \
        \    AND m.forwarded_in_message_id IS NULL \
        \    AND m.received_at > ? \
        \    AND (m.user_id = ? OR m.rendered_text LIKE ? OR m.rendered_text LIKE ? \
        \         OR EXISTS (SELECT 1 FROM messages b \
        \                     WHERE b.message_id = m.reply_to_message_id \
        \                       AND b.user_id = ?) \
        \         OR EXISTS (SELECT 1 FROM messages r \
        \                     WHERE r.reply_to_message_id = m.message_id \
        \                       AND r.user_id = ?)) \
        \  ORDER BY m.received_at DESC \
        \  LIMIT ?"
        ((gid, excludeId, botId) :. (t, botId, mentionLike :: Text, mentionTokLike) :. (botId, botId, n))
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
      "SELECT message_id, user_id, self_id, sender_nickname, sender_card, rendered_text, received_at, reply_to_message_id \
      \  FROM messages \
      \  WHERE message_id IN ?"
      (Only (In ids))
  -- Re-order to match input.
  let byId = [(r.messageId, r) | r <- rows :: [HistoryItem]]
  pure [r | i <- ids, Just r <- [lookup i byId]]

-- | The stored contents of a forwarded chat record: the synthetic
-- child rows the forward worker filed under @container@, in original
-- order.  Timestamps prefer the *original* send time (the synthetic
-- row's received_at is merely when we fetched the bundle).
fetchForwardChildren ::
  (WithConnection :> es, IOE :> es) =>
  Int64 -> -- container message id
  Int -> -- cap
  Eff es [HistoryItem]
fetchForwardChildren containerId cap =
  query
    "SELECT message_id, user_id, self_id, sender_nickname, sender_card, rendered_text, \
    \       COALESCE(original_sent_at, received_at), reply_to_message_id \
    \  FROM messages \
    \  WHERE forwarded_in_message_id = ? \
    \  ORDER BY forward_position \
    \  LIMIT ?"
    (containerId, cap)
