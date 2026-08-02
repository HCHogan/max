module Max.DB.History
  ( HistoryItem (..),
    MessageCursor (..),
    LedgerItem (..),
    HistoryPage (..),
    bestName,
    fetchRecentInGroup,
    fetchPromptLedgerAfter,
    fetchNewestPromptPageBefore,
    fetchTranscriptAfter,
    fetchOldestPageAfter,
    fetchOldestPageThrough,
    pageEndCursor,
    hasMessagesAfter,
    fetchMessageInScope,
    fetchMessagesByIdsInScope,
    fetchForwardChildrenInScope,
    messageStatsDaily,
  )
where

import Control.Applicative ((<|>))
import Data.Int (Int64)
import Data.Maybe (listToMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (Day, UTCTime)
import Database.PostgreSQL.Simple (FromRow, In (..), Only (..), (:.) (..))
import Database.PostgreSQL.Simple.FromRow (field, fromRow)
import Effectful
import Effectful.PostgreSQL (WithConnection, query)
import Max.ConversationScope (ConversationScope, conversationStorageId)

-- | A database-owned total order over message ingestion.  Unlike platform
-- message ids or timestamps, this is unique and monotonic.
newtype MessageCursor = MessageCursor {ingestSeq :: Int64}
  deriving stock (Show, Eq, Ord)

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

-- | One raw-ledger row together with whether the old memory extractor should
-- render it into its transcript.  Pagination includes every row before this
-- policy flag is considered, so filtered commands/synthetic/forward children
-- cannot create cursor holes.
data LedgerItem = LedgerItem
  { cursor :: !MessageCursor,
    history :: !HistoryItem,
    transcriptEligible :: !Bool
  }
  deriving stock (Show)

instance FromRow LedgerItem where
  fromRow =
    LedgerItem
      <$> (MessageCursor <$> field)
      <*> fromRow
      <*> field

data HistoryPage = HistoryPage
  { items :: ![LedgerItem],
    hasMore :: !Bool
  }
  deriving stock (Show)

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
        \    AND kind = 'chat' \
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
        \    AND kind = 'chat' \
        \    AND received_at > ? \
        \  ORDER BY received_at DESC \
        \  LIMIT ?"
        ((gid, excludeId) :. Only t :. Only n)
  pure (reverse (rows :: [HistoryItem]))

-- | Every prompt-eligible chat row after an exact conversation cursor,
-- ordered by the database ingestion sequence.  This complete-range helper is
-- retained for exact diagnostics/tests; production prompt collection uses
-- 'fetchNewestPromptPageBefore' so an arbitrarily long ledger is never loaded
-- merely to be trimmed by the pure token policy.
--
-- The current trigger is excluded because it is rendered separately.  A
-- user's @!clear@ watermark remains a prompt-visibility boundary even though
-- the immutable source ledger and its compartments are retained.
fetchTranscriptAfter ::
  (WithConnection :> es, IOE :> es) =>
  ConversationScope ->
  MessageCursor ->
  Int64 ->
  Maybe UTCTime ->
  Eff es [HistoryItem]
fetchTranscriptAfter scope (MessageCursor after) excludeId since =
  map (.history) <$> fetchPromptLedgerAfter scope (MessageCursor after) excludeId since

-- | Cursor-bearing form of 'fetchTranscriptAfter', used to decide exactly
-- which precomputed compartments can replace enough raw tokens at a high-water
-- materialization boundary.
fetchPromptLedgerAfter ::
  (WithConnection :> es, IOE :> es) =>
  ConversationScope ->
  MessageCursor ->
  Int64 ->
  Maybe UTCTime ->
  Eff es [LedgerItem]
fetchPromptLedgerAfter scope (MessageCursor after) excludeId since =
  case since of
    Nothing ->
      query
        "SELECT ingest_seq, message_id, user_id, self_id, sender_nickname, sender_card, rendered_text, received_at, reply_to_message_id, true \
        \  FROM messages \
        \  WHERE group_id = ? AND ingest_seq > ? AND message_id <> ? \
        \    AND forwarded_in_message_id IS NULL \
        \    AND (NOT is_synthetic OR user_id = self_id) AND kind = 'chat' \
        \  ORDER BY ingest_seq ASC"
        (conversationStorageId scope, after, excludeId)
    Just cleared ->
      query
        "SELECT ingest_seq, message_id, user_id, self_id, sender_nickname, sender_card, rendered_text, received_at, reply_to_message_id, true \
        \  FROM messages \
        \  WHERE group_id = ? AND ingest_seq > ? AND message_id <> ? \
        \    AND forwarded_in_message_id IS NULL \
        \    AND (NOT is_synthetic OR user_id = self_id) AND kind = 'chat' \
        \    AND received_at > ? \
        \  ORDER BY ingest_seq ASC"
        ((conversationStorageId scope, after, excludeId) :. Only cleared)

-- | Read one newest-first I/O page inside an exact cursor tail, returning the
-- page itself in chronological order.  @before@ is an exclusive continuation
-- cursor for paging backward.  The caller owns the token budget; this internal
-- row count only bounds each SQL result and therefore cannot become a context
-- selection policy.
fetchNewestPromptPageBefore ::
  (WithConnection :> es, IOE :> es) =>
  ConversationScope ->
  MessageCursor ->
  Maybe MessageCursor ->
  Int64 ->
  Maybe UTCTime ->
  Int ->
  Eff es HistoryPage
fetchNewestPromptPageBefore scope (MessageCursor after) before excludeId since requestedSize = do
  let pageSize = max 1 requestedSize
      beforeSeq = (.ingestSeq) <$> before
  rows <-
    query
      "SELECT ingest_seq, message_id, user_id, self_id, sender_nickname, sender_card, rendered_text, received_at, reply_to_message_id, true \
      \  FROM messages \
      \  WHERE group_id = ? AND ingest_seq > ? \
      \    AND (?::bigint IS NULL OR ingest_seq < ?) \
      \    AND message_id <> ? \
      \    AND forwarded_in_message_id IS NULL \
      \    AND (NOT is_synthetic OR user_id = self_id) AND kind = 'chat' \
      \    AND (?::timestamptz IS NULL OR received_at > ?) \
      \  ORDER BY ingest_seq DESC \
      \  LIMIT ?"
      ( conversationStorageId scope,
        after,
        beforeSeq,
        beforeSeq,
        excludeId,
        since,
        since,
        pageSize + 1
      )
  let allRows = rows :: [LedgerItem]
      newestPage = take pageSize allRows
  pure
    HistoryPage
      { items = reverse newestPage,
        hasMore = length allRows > pageSize
      }

-- | Read the oldest raw ledger rows strictly after a cursor.  Fetching one
-- extra row makes continuation explicit without advancing beyond data the
-- caller actually received.
fetchOldestPageAfter ::
  (WithConnection :> es, IOE :> es) =>
  ConversationScope ->
  MessageCursor ->
  Int ->
  Eff es HistoryPage
fetchOldestPageAfter scope (MessageCursor after) requestedSize = do
  let pageSize = max 1 requestedSize
  rows <-
    query
      "SELECT ingest_seq, \
      \       message_id, user_id, self_id, sender_nickname, sender_card, rendered_text, received_at, reply_to_message_id, \
      \       (forwarded_in_message_id IS NULL AND (NOT is_synthetic OR user_id = self_id) AND kind = 'chat') \
      \  FROM messages \
      \  WHERE group_id = ? AND ingest_seq > ? \
      \  ORDER BY ingest_seq ASC \
      \  LIMIT ?"
      (conversationStorageId scope, after, pageSize + 1)
  let allRows = rows :: [LedgerItem]
  pure
    HistoryPage
      { items = take pageSize allRows,
        hasMore = length allRows > pageSize
      }

-- | Bounded variant used by historical backfill.  The inclusive upper cursor
-- is the final raw row before the next active compartment, so pagination can
-- never drift into a range that already has an owner.
fetchOldestPageThrough ::
  (WithConnection :> es, IOE :> es) =>
  ConversationScope ->
  MessageCursor ->
  MessageCursor ->
  Int ->
  Eff es HistoryPage
fetchOldestPageThrough scope (MessageCursor after) (MessageCursor through) requestedSize = do
  let pageSize = max 1 requestedSize
  rows <-
    query
      "SELECT ingest_seq, \
      \       message_id, user_id, self_id, sender_nickname, sender_card, rendered_text, received_at, reply_to_message_id, \
      \       (forwarded_in_message_id IS NULL AND (NOT is_synthetic OR user_id = self_id) AND kind = 'chat') \
      \  FROM messages \
      \  WHERE group_id = ? AND ingest_seq > ? AND ingest_seq <= ? \
      \  ORDER BY ingest_seq ASC \
      \  LIMIT ?"
      (conversationStorageId scope, after, through, pageSize + 1)
  let allRows = rows :: [LedgerItem]
  pure
    HistoryPage
      { items = take pageSize allRows,
        hasMore = length allRows > pageSize
      }

pageEndCursor :: HistoryPage -> Maybe MessageCursor
pageEndCursor page = case reverse page.items of
  row : _ -> Just row.cursor
  [] -> Nothing

hasMessagesAfter ::
  (WithConnection :> es, IOE :> es) =>
  ConversationScope ->
  MessageCursor ->
  Eff es Bool
hasMessagesAfter scope (MessageCursor after) = do
  rows <-
    query
      "SELECT EXISTS ( \
      \  SELECT 1 FROM messages \
      \  WHERE group_id = ? AND ingest_seq > ? \
      \)"
      (conversationStorageId scope, after)
  pure $ case rows :: [Only Bool] of
    Only pending : _ -> pending
    [] -> False

-- | One message by id, confined to the current conversation.
fetchMessageInScope ::
  (WithConnection :> es, IOE :> es) =>
  ConversationScope ->
  Int64 ->
  Eff es (Maybe HistoryItem)
fetchMessageInScope scope mid = do
  rows <-
    query
      "SELECT message_id, user_id, self_id, sender_nickname, sender_card, rendered_text, received_at, reply_to_message_id \
      \  FROM messages \
      \  WHERE group_id = ? AND message_id = ? \
      \  LIMIT 1"
      (conversationStorageId scope, mid)
  pure (listToMaybe (rows :: [HistoryItem]))

-- | Bulk fetch by message id.  Preserves the order of input ids
-- (which is what !pin expects — display the user's chosen order).
fetchMessagesByIdsInScope ::
  (WithConnection :> es, IOE :> es) =>
  ConversationScope ->
  [Int64] ->
  Eff es [HistoryItem]
fetchMessagesByIdsInScope _ [] = pure []
fetchMessagesByIdsInScope scope ids = do
  rows <-
    query
      "SELECT message_id, user_id, self_id, sender_nickname, sender_card, rendered_text, received_at, reply_to_message_id \
      \  FROM messages \
      \  WHERE group_id = ? AND message_id IN ?"
      (conversationStorageId scope, In ids)
  -- Re-order to match input.
  let byId = [(r.messageId, r) | r <- rows :: [HistoryItem]]
  pure [r | i <- ids, Just r <- [lookup i byId]]

-- | The stored contents of a forwarded chat record: the synthetic
-- child rows the forward worker filed under @container@, in original
-- order.  Timestamps prefer the *original* send time (the synthetic
-- row's received_at is merely when we fetched the bundle).
fetchForwardChildrenInScope ::
  (WithConnection :> es, IOE :> es) =>
  ConversationScope ->
  Int64 -> -- container message id
  Int -> -- cap
  Eff es [HistoryItem]
fetchForwardChildrenInScope scope containerId cap =
  query
    "SELECT child.message_id, child.user_id, child.self_id, child.sender_nickname, child.sender_card, child.rendered_text, \
    \       COALESCE(child.original_sent_at, child.received_at), child.reply_to_message_id \
    \  FROM messages child \
    \  WHERE child.group_id = ? \
    \    AND child.forwarded_in_message_id = ? \
    \    AND EXISTS (SELECT 1 FROM messages container \
    \                 WHERE container.group_id = ? AND container.message_id = ?) \
    \  ORDER BY child.forward_position \
    \  LIMIT ?"
    (conversationStorageId scope, containerId, conversationStorageId scope, containerId, cap)

-- | Message volume per (day, group, kind) over the last @days@ days,
-- for the admin stats endpoint.  Day boundaries in the configured
-- display timezone, passed as a minute offset (the config zone is
-- fixed-offset — no DST to honour).
messageStatsDaily ::
  (WithConnection :> es, IOE :> es) =>
  Int -> -- timezone offset, minutes east of UTC
  Int -> -- how many days back
  Eff es [(Day, Int64, Text, Int64)]
messageStatsDaily tzMinutes days =
  query
    "SELECT (received_at + make_interval(mins => ?))::date AS day, \
    \       group_id, kind, count(*)::bigint \
    \  FROM messages \
    \ WHERE received_at > now() - make_interval(days => ?) \
    \ GROUP BY 1, 2, 3 \
    \ ORDER BY 1 DESC, 2, 3"
    (tzMinutes, days)
