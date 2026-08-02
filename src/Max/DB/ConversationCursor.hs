-- |
-- Durable, conversation-scoped progress for background consumers of the
-- immutable message ledger.
--
-- Cursor names are host-owned capabilities.  Callers cannot construct an
-- arbitrary name from model input, and every read/update is partitioned by the
-- current 'ConversationScope'.  Advancement uses compare-and-swap so a stale
-- worker can never move progress backwards or overwrite a newer publication.
module Max.DB.ConversationCursor
  ( CursorKind,
    memoryExtractCursor,
    historianCursor,
    loadCursor,
    advanceCursor,
    advanceCursorBefore,
  )
where

import Control.Monad (void)
import Data.Int (Int64)
import Data.Text (Text)
import Data.Time (UTCTime)
import Database.PostgreSQL.Simple (Only (..))
import Effectful
import Effectful.PostgreSQL (WithConnection, execute, query)
import Max.ConversationScope (ConversationScope, conversationStorageId)
import Max.DB.History (MessageCursor (..))

-- | A host-defined cursor consumer.  Keep the constructor private so an
-- untrusted string cannot select or mutate another worker's progress.
newtype CursorKind = CursorKind Text

memoryExtractCursor :: CursorKind
memoryExtractCursor = CursorKind "memory_extract"

historianCursor :: CursorKind
historianCursor = CursorKind "historian"

-- | Read a cursor, creating it at the beginning of the ledger when this is a
-- new conversation/consumer pair.
loadCursor ::
  (WithConnection :> es, IOE :> es) =>
  ConversationScope ->
  CursorKind ->
  Eff es MessageCursor
loadCursor scope (CursorKind name) = do
  let conversationId = conversationStorageId scope
  void $
    execute
      "INSERT INTO conversation_cursors (conversation_id, cursor_name, ingest_seq) \
      \ VALUES (?, ?, 0) \
      \ ON CONFLICT (conversation_id, cursor_name) DO NOTHING"
      (conversationId, name)
  rows <-
    query
      "SELECT ingest_seq \
      \  FROM conversation_cursors \
      \  WHERE conversation_id = ? AND cursor_name = ?"
      (conversationId, name)
  case rows :: [Only Int64] of
    Only cursor : _ -> pure (MessageCursor cursor)
    [] -> error "conversation cursor disappeared after initialization"

-- | Advance from exactly @expected@ to @next@.  Returns 'False' on stale CAS
-- or a non-forward move; in either case the stored cursor is unchanged.
advanceCursor ::
  (WithConnection :> es, IOE :> es) =>
  ConversationScope ->
  CursorKind ->
  MessageCursor ->
  MessageCursor ->
  Eff es Bool
advanceCursor scope (CursorKind name) (MessageCursor expected) (MessageCursor next)
  | next <= expected = pure False
  | otherwise = do
      changed <-
        execute
          "UPDATE conversation_cursors \
          \  SET ingest_seq = ?, updated_at = now() \
          \  WHERE conversation_id = ? \
          \    AND cursor_name = ? \
          \    AND ingest_seq = ?"
          (next, conversationStorageId scope, name, expected)
      pure (changed == 1)

-- | Apply an explicit user clear-watermark.  This is the one legal cursor
-- jump: the user asked to ignore history before the cutoff.  The strict @<@
-- comparison conservatively replays rows exactly at the timestamp instead of
-- risking a loss at a non-unique time boundary.
advanceCursorBefore ::
  (WithConnection :> es, IOE :> es) =>
  ConversationScope ->
  CursorKind ->
  UTCTime ->
  Eff es MessageCursor
advanceCursorBefore scope kind@(CursorKind name) cutoff = do
  current@(MessageCursor currentSeq) <- loadCursor scope kind
  rows <-
    query
      "SELECT COALESCE(max(ingest_seq), 0) \
      \  FROM messages \
      \  WHERE group_id = ? AND received_at < ?"
      (conversationStorageId scope, cutoff)
  let floorSeq = case rows :: [Only Int64] of
        Only n : _ -> n
        [] -> 0
  if floorSeq <= currentSeq
    then pure current
    else do
      void $
        execute
          "UPDATE conversation_cursors \
          \  SET ingest_seq = GREATEST(ingest_seq, ?), updated_at = now() \
          \  WHERE conversation_id = ? AND cursor_name = ?"
          (floorSeq, conversationStorageId scope, name)
      loadCursor scope kind
