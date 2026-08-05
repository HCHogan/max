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
import Data.Maybe (fromMaybe, listToMaybe)
import Data.Text (Text)
import Data.Time (Day, UTCTime)
import Database.PostgreSQL.Simple (FromRow, In (..), Only (..), Query, (:.) (..))
import Database.PostgreSQL.Simple.FromRow (field, fromRow)
import Effectful
import Effectful.PostgreSQL (WithConnection, query)
import Max.ConversationScope (ConversationScope, conversationStorageId)
import Max.IR (nonBlank)
import Max.Util (tshow)

-- | A database-owned total order over message ingestion.  Unlike platform
-- message ids or timestamps, this is unique and monotonic.
newtype MessageCursor = MessageCursor {ingestSeq :: Int64}
  deriving stock (Show, Eq, Ord)

-- | The fields needed to render a message as a line of prompt context.
--
-- Every identifier here is the canonical one (ADR 004): 'canonicalId' is
-- what the model reads as @#\<id\>@ and passes back to every tool, and
-- 'authorPrincipalId' is what it reads as @[\@#\<id\>]@.  The
-- compatibility bigints are not projected at all — they exist for the
-- session/command/admin plumbing, and nothing that renders to a model or a
-- human needs them.
data HistoryItem = HistoryItem
  { canonicalId :: !Int64,
    authorPrincipalId :: !Int64,
    -- | Did the bot say this?  Decided in SQL by comparing two
    -- compatibility columns of the /same row/ — @self_id@ is the bot's id
    -- on the endpoint that carried this message, so the comparison is
    -- within one id space by construction and stays correct for the
    -- pre-ADR-003 rows that predate 'message_origin'.
    fromBot :: !Bool,
    senderNickname :: !(Maybe Text),
    -- | 群名片 — the sender's per-group display name.  This is what
    -- other members actually see and call them by, so rendering
    -- prefers it over the (global) nickname.
    senderCard :: !(Maybe Text),
    renderedText :: !Text,
    receivedAt :: !UTCTime,
    -- | The message this one quotes (@reply_to_canonical_message_id@), if
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

-- | The column list every 'HistoryItem' query selects, in 'FromRow' order.
-- One definition because a projection that drifts between two of these
-- reads as a different message to whichever consumer got the stale one.
historyColumns :: Query
historyColumns =
  "canonical_message_id, author_principal_id, (user_id = self_id), \
  \sender_nickname, sender_card, rendered_text, received_at, \
  \reply_to_canonical_message_id"

-- | Same columns, qualified by a table alias.
historyColumnsOf :: Query -> Query
historyColumnsOf alias =
  alias
    <> ".canonical_message_id, "
    <> alias
    <> ".author_principal_id, ("
    <> alias
    <> ".user_id = "
    <> alias
    <> ".self_id), "
    <> alias
    <> ".sender_nickname, "
    <> alias
    <> ".sender_card, "
    <> alias
    <> ".rendered_text"

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
    LedgerItem . MessageCursor
      <$> field
      <*> fromRow
      <*> field

data HistoryPage = HistoryPage
  { items :: ![LedgerItem],
    hasMore :: !Bool
  }
  deriving stock (Show)

-- | How a speaker is named in every transcript: what the other members see —
-- 群名片 first, then nickname, then the bare principal id when the platform
-- gave us neither (QQ sends @\"\"@ for an unset card, so blanks count as
-- absent).
--
-- Deliberately no platform label.  Which transport carried a message is
-- routing metadata: the delivery layer needs it to pick capabilities and to
-- attribute a mirrored copy, the model does not.  Naming it here did two
-- things wrong — it made the unlabelled platform the transcript's implicit
-- home, and it split one principal into "QQ · 张三" and "Matrix · 张三",
-- which is precisely what principal identities exist to prevent.
bestName :: HistoryItem -> Text
bestName h =
  fromMaybe (tshow h.authorPrincipalId) (blankless h.senderCard <|> blankless h.senderNickname)
  where
    blankless = (>>= nonBlank)

-- | Last @n@ real (non-synthetic, non-forward-child) messages in @gid@,
-- *excluding* @excludeId@.  When @since@ is @Just@, also filters out
-- anything older than that timestamp (used by @!clear@'s watermark).
-- Returned chronological (oldest first).
fetchRecentInGroup ::
  (WithConnection :> es, IOE :> es) =>
  Int64 -> -- group id
  Int64 -> -- canonical message id to exclude (usually the triggering message)
  Maybe UTCTime -> -- only include messages strictly newer than this
  Int -> -- how many
  Eff es [HistoryItem]
fetchRecentInGroup gid excludeId since n = do
  rows <- case since of
    Nothing ->
      query
        (selectHistory <> promptFilters <> " ORDER BY received_at DESC LIMIT ?")
        (gid, excludeId, n)
    Just t ->
      query
        (selectHistory <> promptFilters <> " AND received_at > ? ORDER BY received_at DESC LIMIT ?")
        ((gid, excludeId) :. Only t :. Only n)
  pure (reverse (rows :: [HistoryItem]))
  where
    selectHistory = "SELECT " <> historyColumns <> " FROM messages WHERE group_id = ? AND canonical_message_id <> ?"
    promptFilters =
      " AND NOT EXISTS (SELECT 1 FROM message_relations containment \
      \                 WHERE containment.canonical_message_id = messages.canonical_message_id \
      \                   AND containment.relation_kind = 'contained_in') \
      \ AND NOT is_synthetic AND kind = 'chat'"

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
        (selectLedger <> " ORDER BY ingest_seq ASC")
        (conversationStorageId scope, after, excludeId)
    Just cleared ->
      query
        (selectLedger <> " AND received_at > ? ORDER BY ingest_seq ASC")
        ((conversationStorageId scope, after, excludeId) :. Only cleared)
  where
    selectLedger =
      "SELECT ingest_seq, "
        <> historyColumns
        <> ", true FROM messages \
           \ WHERE group_id = ? AND ingest_seq > ? AND canonical_message_id <> ? \
           \   AND NOT EXISTS (SELECT 1 FROM message_relations containment \
           \                   WHERE containment.canonical_message_id = messages.canonical_message_id \
           \                     AND containment.relation_kind = 'contained_in') \
           \   AND (NOT is_synthetic OR user_id = self_id) AND kind = 'chat'"

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
      ( "SELECT ingest_seq, "
          <> historyColumns
          <> ", true FROM messages \
             \ WHERE group_id = ? AND ingest_seq > ? \
             \   AND (?::bigint IS NULL OR ingest_seq < ?) \
             \   AND canonical_message_id <> ? \
             \   AND NOT EXISTS (SELECT 1 FROM message_relations containment \
             \                   WHERE containment.canonical_message_id = messages.canonical_message_id \
             \                     AND containment.relation_kind = 'contained_in') \
             \   AND (NOT is_synthetic OR user_id = self_id) AND kind = 'chat' \
             \   AND (?::timestamptz IS NULL OR received_at > ?) \
             \ ORDER BY ingest_seq DESC \
             \ LIMIT ?"
      )
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
      ( "SELECT ingest_seq, "
          <> historyColumns
          <> ", "
          <> transcriptEligibleExpr
          <> " FROM messages \
             \ WHERE group_id = ? AND ingest_seq > ? \
             \ ORDER BY ingest_seq ASC \
             \ LIMIT ?"
      )
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
      ( "SELECT ingest_seq, "
          <> historyColumns
          <> ", "
          <> transcriptEligibleExpr
          <> " FROM messages \
             \ WHERE group_id = ? AND ingest_seq > ? AND ingest_seq <= ? \
             \ ORDER BY ingest_seq ASC \
             \ LIMIT ?"
      )
      (conversationStorageId scope, after, through, pageSize + 1)
  let allRows = rows :: [LedgerItem]
  pure
    HistoryPage
      { items = take pageSize allRows,
        hasMore = length allRows > pageSize
      }

transcriptEligibleExpr :: Query
transcriptEligibleExpr =
  "(NOT EXISTS (SELECT 1 FROM message_relations containment \
  \             WHERE containment.canonical_message_id = messages.canonical_message_id \
  \               AND containment.relation_kind = 'contained_in') \
  \ AND (NOT is_synthetic OR user_id = self_id) AND kind = 'chat')"

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

-- | One message by canonical id, confined to the current conversation.
fetchMessageInScope ::
  (WithConnection :> es, IOE :> es) =>
  ConversationScope ->
  Int64 ->
  Eff es (Maybe HistoryItem)
fetchMessageInScope scope canonical = do
  rows <-
    query
      ( "SELECT "
          <> historyColumns
          <> " FROM messages WHERE group_id = ? AND canonical_message_id = ? LIMIT 1"
      )
      (conversationStorageId scope, canonical)
  pure (listToMaybe (rows :: [HistoryItem]))

-- | Bulk fetch by canonical message id.  Preserves the order of input ids
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
      ( "SELECT "
          <> historyColumns
          <> " FROM messages WHERE group_id = ? AND canonical_message_id IN ?"
      )
      (conversationStorageId scope, In ids)
  -- Re-order to match input.
  let byId = [(r.canonicalId, r) | r <- rows :: [HistoryItem]]
  pure [r | i <- ids, Just r <- [lookup i byId]]

-- | Canonical children linked to a forwarded chat record, in wire order.
-- Their @occurred_at@ is the original send time captured by the adapter;
-- @received_at@ only says when the chain was fetched.
fetchForwardChildrenInScope ::
  (WithConnection :> es, IOE :> es) =>
  ConversationScope ->
  Int64 -> -- container canonical message id
  Int -> -- cap
  Eff es [HistoryItem]
fetchForwardChildrenInScope scope containerId cap =
  query
    ( "SELECT "
        <> historyColumnsOf "child"
        <> ", child.occurred_at, child.reply_to_canonical_message_id \
           \ FROM messages child \
           \ JOIN message_relations containment \
           \   ON containment.canonical_message_id = child.canonical_message_id \
           \  AND containment.relation_kind = 'contained_in' \
           \ JOIN messages container \
           \   ON container.canonical_message_id = containment.target_canonical_message_id \
           \ WHERE child.group_id = ? \
           \   AND container.group_id = ? AND container.canonical_message_id = ? \
           \ ORDER BY containment.relation_position, containment.relation_id \
           \ LIMIT ?"
    )
    (conversationStorageId scope, conversationStorageId scope, containerId, cap)

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
