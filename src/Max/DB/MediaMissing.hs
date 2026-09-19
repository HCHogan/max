-- | Missing media sources and completed forward expansions.
module Max.DB.MediaMissing (missingMediaMessages, storedMedia, forwardExpanded, recordForwardExpansion) where

import Data.Int (Int64)
import Data.Maybe (listToMaybe)
import Data.Text (Text)
import Database.PostgreSQL.Simple (Only (..))
import Effectful
import Effectful.PostgreSQL (WithConnection, execute, query)
import Max.FetchQueue (ForwardJob (..), MediaKind (..))
import Max.Platform.Types (CanonicalMessageId (..))

-- | Return the last scanned ID and missing sources; True permits top-level forward expansion.
missingMediaMessages :: (WithConnection :> es, IOE :> es) => Int64 -> Eff es (Int64, [(CanonicalMessageId, Bool)])
missingMediaMessages after = do
  rows <-
    query
      "WITH source AS ( \
      \   SELECT * FROM messages WHERE canonical_message_id > ? \
      \   ORDER BY canonical_message_id LIMIT 128 \
      \ ) \
      \ SELECT m.canonical_message_id, m.source_native_event_id NOT LIKE 'forward:%', \
      \   m.message_origin IN ('inbound','legacy') AND EXISTS ( \
      \     SELECT 1 FROM jsonb_array_elements(m.canonical_content->'nodes') \
      \       WITH ORDINALITY AS n(node,position) \
      \     WHERE ( \
      \       node->>'type'='media' AND node->>'source' IS NOT NULL \
      \       AND node->>'source' NOT LIKE 'blob:%' AND ( \
      \         (node->>'kind' IN ('image','sticker') AND NOT EXISTS ( \
      \           SELECT 1 FROM message_images i \
      \           WHERE i.canonical_message_id=m.canonical_message_id AND i.seg_index=n.position-1)) \
      \         OR (node->>'kind'='video' AND lower(node->>'source') LIKE 'http%' AND NOT EXISTS ( \
      \           SELECT 1 FROM message_videos v \
      \           WHERE v.canonical_message_id=m.canonical_message_id AND v.seg_index=n.position-1)) \
      \       ) \
      \     ) OR ( \
      \       node->>'type'='media' AND node->>'kind'='file' \
      \       AND COALESCE(node->'raw'->'data'->>'file_id',node->'raw'->'data'->>'file') IS NOT NULL \
      \       AND NOT EXISTS ( \
      \         SELECT 1 FROM group_files f WHERE f.sha256 IS NOT NULL \
      \           AND f.file_id=COALESCE(node->'raw'->'data'->>'file_id',node->'raw'->'data'->>'file')) \
      \     ) OR ( \
      \       node->>'type'='forward' AND m.source_native_event_id NOT LIKE 'forward:%' \
      \       AND NOT EXISTS ( \
      \         SELECT 1 FROM forward_expansions f \
      \         WHERE f.canonical_message_id=m.canonical_message_id AND f.forward_id=node->>'native_id') \
      \     ) \
      \   ) \
      \ FROM source m ORDER BY m.canonical_message_id"
      (Only after)
  pure (maximum (after : [message | (message, _, _) <- rows]), [(CanonicalMessageId message, topLevel) | (message, topLevel, True) <- rows])

storedMedia :: (WithConnection :> es, IOE :> es) => MediaKind -> Int64 -> Int -> Eff es (Maybe Text)
storedMedia kind message index = do
  rows <-
    query
      ( case kind of
          MediaImage -> "SELECT sha256 FROM message_images WHERE canonical_message_id=? AND seg_index=?"
          MediaVideo -> "SELECT sha256 FROM message_videos WHERE canonical_message_id=? AND seg_index=?"
      )
      (message, index)
  pure (fromOnly <$> listToMaybe rows)

forwardExpanded :: (WithConnection :> es, IOE :> es) => ForwardJob -> Eff es Bool
forwardExpanded job = do
  rows <- query "SELECT 1 FROM forward_expansions WHERE canonical_message_id=? AND forward_id=?" (job.containerMessageId, job.forwardId)
  pure (not (null (rows :: [Only Int])))

recordForwardExpansion :: (WithConnection :> es, IOE :> es) => ForwardJob -> Int -> Eff es ()
recordForwardExpansion job count = do
  _ <- execute "INSERT INTO forward_expansions(canonical_message_id,forward_id,top_level_count) VALUES (?,?,?) ON CONFLICT DO NOTHING" (job.containerMessageId, job.forwardId, count)
  pure ()
