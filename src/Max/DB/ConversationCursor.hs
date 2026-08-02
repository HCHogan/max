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
    historianCursor,
    loadCursor,
    advanceCursor,
  )
where

import Control.Monad (void)
import Data.Int (Int64)
import Data.Text (Text)
import Database.PostgreSQL.Simple (Only (..))
import Effectful
import Effectful.PostgreSQL (WithConnection, execute, query)
import Max.ConversationScope (ConversationScope, conversationStorageId)
import Max.DB.History (MessageCursor (..))

-- | A host-defined cursor consumer.  Keep the constructor private so an
-- untrusted string cannot select or mutate another worker's progress.
newtype CursorKind = CursorKind Text

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
