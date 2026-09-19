-- | Batch embeddings for messages, memories, summaries and sticker captions.
-- Scanning stored rows covers both new writes and backfill without write-path
-- hooks. Failed embeddings remain eligible for a later tick.
module Max.Embedder
  ( embedWorker,
  )
where

import Control.Concurrent (threadDelay)
import Control.Monad (forever)
import Data.Int (Int64)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Database.PostgreSQL.Simple (Query)
import Database.PostgreSQL.Simple.ToField (ToField)
import Effectful
import Effectful.Log
import Effectful.PostgreSQL (WithConnection, execute, query)
import Max.DB.History (notForwardChild)
import Max.Effects.Embedding (Embedding, EmbeddingSpace (..), embedBatch, embeddingSpace, renderEmbeddingFault)
import Max.Embedding (EmbeddingRecord (..))
import Max.Embedding.Maintenance (EmbeddingLock, tryWithEmbeddingLock)
import Max.MemoryStore
  ( PendingMemoryEmbedding (..),
    listPendingMemoryEmbeddings,
    markPendingMemoryEmbedded,
  )
import Max.Util (catchSync)

-- | Maximum rows per corpus in one batch.
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
  EmbeddingLock ->
  Eff es ()
embedWorker lock = forever $ do
  delay <-
    runTick `catchSync` \e -> do
      logAttention "embed: tick crashed" $ object ["error" .= T.pack (show e)]
      pure errorMicros
  liftIO (threadDelay delay)
  where
    runTick =
      embeddingSpace >>= \case
        Nothing -> do
          logAttention "embed: effect has no configured space" (object [])
          pure errorMicros
        Just space -> fromMaybe idleMicros <$> tryWithEmbeddingLock lock (tick space)

    -- The metadata consistency constraint makes an absent embedding imply an
    -- absent model. The model-mismatch predicate covers both without an OR that
    -- would prevent the intended index scan.
    pendingMessages modelId = do
      fresh <-
        query
          ( "SELECT message_id, rendered_text FROM messages \
            \ WHERE embedding IS NULL AND NOT is_synthetic \
            \   AND char_length(rendered_text) >= 4 AND "
              <> notForwardChild "messages"
              <> " ORDER BY received_at DESC LIMIT 64"
          )
          ()
      if not (null (fresh :: [(Int64, Text)]))
        then pure fresh
        else do
          -- Re-embedding after a model change is a deploy-time backfill, not
          -- something steady state ever needs.  min/max over the model btree
          -- settles it in two index lookups, so the scan below only happens
          -- on the day it is actually true.
          spread <-
            query
              "SELECT min(embedding_model), max(embedding_model) FROM messages WHERE embedding IS NOT NULL"
              ()
          case spread :: [(Maybe Text, Maybe Text)] of
            [(Just lo, Just hi)] | lo == modelId && hi == modelId -> pure []
            _ ->
              query
                ( "SELECT message_id, rendered_text FROM messages \
                  \ WHERE embedding IS NOT NULL AND embedding_model <> ? \
                  \   AND NOT is_synthetic AND char_length(rendered_text) >= 4 AND "
                    <> notForwardChild "messages"
                    <> " ORDER BY received_at DESC LIMIT 64"
                )
                [modelId]

    tick space = do
      -- Recent-first so fresh messages become searchable immediately
      -- while the historical backfill trickles along behind.
      let modelId = space.esModelId
      msgs <- pendingMessages modelId
      mems <- listPendingMemoryEmbeddings modelId batchSize
      episodes <-
        query
          "SELECT id, summary FROM conversation_compartments \
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
        then pure idleMicros
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
              \ WHERE id = ? AND summary = ? AND state = 'active'"
              episodes
          okS <-
            embedInto
              "UPDATE stickers SET embedding = ?::vector, embedding_model = ?, \
              \ embedding_dimensions = ?, embedding_content_hash = ?, embedding_updated_at = now() \
              \ WHERE sha256 = ? AND description = ?"
              stickers
          pure (if okM && okR && okE && okS then busyMicros else errorMicros)

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
              ( \(i, source, record) ->
                  execute
                    sql
                    ( record.erVector,
                      record.erModelId,
                      record.erDimensions,
                      record.erContentHash,
                      i,
                      source
                    )
              )
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
