-- |
-- Background embedding worker: polls for rows whose @embedding@ is
-- still NULL (new group messages, new/edited memories, active episode
-- summaries, freshly captioned stickers), embeds them in batches through
-- "Max.Embedding", and writes the vectors back.
--
-- Polling instead of write-path hooks on purpose: memories are
-- written from three places (agent tools, the extractor, @!memory@)
-- and messages from the event loop — one poller means zero plumbing
-- at every write site, and boot-time backfill of the pre-existing
-- corpus falls out for free.  Rows that fail to embed stay NULL and
-- are retried on a later tick.
module Max.Embedder
  ( embedWorker,
  )
where

import Control.Concurrent (threadDelay)
import Control.Monad (forever, unless)
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as T
import Database.PostgreSQL.Simple (Query)
import Database.PostgreSQL.Simple.ToField (ToField)
import Effectful
import Effectful.Log
import Effectful.PostgreSQL (WithConnection, execute, query)
import Max.Effects.Embedding (Embedding, EmbeddingSpace (..), embedBatch, embeddingSpace, renderEmbeddingFault)
import Max.Embedding (EmbeddingRecord (..))
import Max.MaintenanceLease
  ( MaintenanceDomain (EmbeddingMaintenance),
    withMaintenanceLease,
  )
import Max.MemoryStore
  ( PendingMemoryEmbedding (..),
    listPendingMemoryEmbeddings,
    markPendingMemoryEmbedded,
  )
import Max.Util (catchSync)

-- | Batch size per tick; embedding APIs are happy with this, and it
-- bounds request size for long messages.
batchSize :: Int
batchSize = 64

-- | Idle sleep between polls when there was nothing to do.
idleMicros :: Int
idleMicros = 20_000_000

-- | Short breather between busy batches (backfill pacing).
busyMicros :: Int
busyMicros = 1_000_000

-- | Sleep after an embedding failure before retrying.
errorMicros :: Int
errorMicros = 60_000_000

embedWorker ::
  forall es.
  (Embedding :> es, WithConnection :> es, Log :> es, IOE :> es) =>
  Text ->
  Eff es ()
embedWorker owner = forever $ do
  runLeasedTick `catchSync` \e -> do
    logAttention "embed: tick crashed" $ object ["error" .= T.pack (show e)]
    liftIO (threadDelay errorMicros)
  where
    runLeasedTick = embeddingSpace >>= \case
      Nothing -> do
        logAttention "embed: effect has no configured space" (object [])
        liftIO (threadDelay errorMicros)
      Just space ->
        withMaintenanceLease EmbeddingMaintenance owner embeddingLeaseSeconds (const (tick space)) >>= \case
          Nothing -> liftIO (threadDelay idleMicros)
          Just () -> pure ()

    tick space = do
      -- Recent-first so fresh messages become searchable immediately
      -- while the historical backfill trickles along behind.
      let modelId = space.esModelId
      msgs <-
        query
          "SELECT message_id, rendered_text FROM messages \
          \ WHERE (embedding IS NULL OR embedding_model IS DISTINCT FROM ?) \
          \   AND NOT is_synthetic \
          \   AND char_length(rendered_text) >= 4 \
          \ ORDER BY received_at DESC LIMIT 64"
          [modelId]
      mems <- listPendingMemoryEmbeddings modelId batchSize
      episodes <-
        query
          "SELECT id, summary_p1 FROM conversation_compartments \
          \ WHERE state = 'active' \
          \   AND (embedding IS NULL OR embedding_model IS DISTINCT FROM ?) \
          \ ORDER BY activated_at DESC NULLS LAST, id DESC LIMIT 64"
          [modelId]
      -- Stickers embed their vision caption (the retrieval key for
      -- send_sticker); rows wait here until the caption worker fills
      -- description in.
      stickers <-
        query
          "SELECT sha256, description FROM stickers \
          \ WHERE (embedding IS NULL OR embedding_model IS DISTINCT FROM ?) \
          \   AND description IS NOT NULL AND NOT banned LIMIT 64"
          [modelId]
      if null (msgs :: [(Int64, Text)])
        && null mems
        && null (episodes :: [(Int64, Text)])
        && null (stickers :: [(Text, Text)])
        then liftIO (threadDelay idleMicros)
        else do
          okM <-
            embedInto
              "UPDATE messages SET embedding = ?::vector, embedding_model = ?, \
              \ embedding_dimensions = ?, embedding_content_hash = ?, embedding_updated_at = now() \
              \ WHERE message_id = ? AND rendered_text = ?"
              msgs
          okR <- embedMemories mems
          okE <-
            embedInto
              "UPDATE conversation_compartments SET embedding = ?::vector, embedding_model = ?, \
              \ embedding_dimensions = ?, embedding_content_hash = ?, embedding_updated_at = now() \
              \ WHERE id = ? AND summary_p1 = ? AND state = 'active'"
              episodes
          okS <-
            embedInto
              "UPDATE stickers SET embedding = ?::vector, embedding_model = ?, \
              \ embedding_dimensions = ?, embedding_content_hash = ?, embedding_updated_at = now() \
              \ WHERE sha256 = ? AND description = ?"
              stickers
          unless (okM && okR && okE && okS) $ liftIO (threadDelay errorMicros)
          liftIO (threadDelay busyMicros)

    -- Embed one batch and write vectors back; False on API failure
    -- (rows stay NULL for retry).  Polymorphic in the key column
    -- (messages/memories use bigint ids, stickers their sha256 text).
    embedInto :: (ToField i) => Query -> [(i, Text)] -> Eff es Bool
    embedInto _ [] = pure True
    embedInto sql rows = do
      let (ids, texts) = unzip (take batchSize rows)
      eres <- embedBatch (map (T.take 2000) texts)
      case eres of
        Left fault -> do
          logAttention "embed: batch failed" $
            object ["error" .= renderEmbeddingFault fault, "rows" .= length ids]
          pure False
        Right records -> do
          written <-
            traverse
              (\(i, source, record) -> execute sql (record.erVector, record.erModelId, record.erDimensions, record.erContentHash, i, source))
              (zip3 ids texts records)
          let stored = sum written
          logInfo "embed: batch done" $
            object ["rows" .= length ids, "stored" .= stored, "stale" .= (fromIntegral (length ids) - stored)]
          pure True

    embedMemories :: [PendingMemoryEmbedding] -> Eff es Bool
    embedMemories [] = pure True
    embedMemories pending = do
      let rows = take batchSize pending
          texts = map (.pendingMemoryContent) rows
      eres <- embedBatch (map (T.take 2000) texts)
      case eres of
        Left fault -> do
          logAttention "embed: memory batch failed" $
            object ["error" .= renderEmbeddingFault fault, "rows" .= length rows]
          pure False
        Right records -> do
          written <- traverse (uncurry markPendingMemoryEmbedded) (zip rows records)
          let stored = length (filter id written)
          logInfo "embed: memory batch done" $
            object ["rows" .= length rows, "stored" .= stored, "stale" .= (length rows - stored)]
          pure True

embeddingLeaseSeconds :: Int
embeddingLeaseSeconds = 300
