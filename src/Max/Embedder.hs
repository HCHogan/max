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
import Effectful.Concurrent (Concurrent)
import Effectful.Log
import Effectful.PostgreSQL (WithConnection, execute, query)
import Max.DB.History (notForwardChild)
import Max.Effects.Embedding (Embedding, EmbeddingSpace (..), embedBatch, embeddingSpace, renderEmbeddingFault)
import Max.Embedding (EmbeddingRecord (..))
import Max.MaintenanceLease
  ( MaintenanceDomain (EmbeddingMaintenance),
    MaintenanceLease (..),
    MaintenanceRun (..),
    maintenanceDomainText,
    withMaintenanceLease,
  )
import Max.MemoryStore
  ( PendingMemoryEmbedding (..),
    listPendingMemoryEmbeddings,
    markPendingMemoryEmbeddedFenced,
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
  (Embedding :> es, Concurrent :> es, WithConnection :> es, Log :> es, IOE :> es) =>
  Text ->
  Eff es ()
embedWorker owner = forever $ do
  runLeasedTick `catchSync` \e -> do
    logAttention "embed: tick crashed" $ object ["error" .= T.pack (show e)]
    liftIO (threadDelay errorMicros)
  where
    runLeasedTick =
      embeddingSpace >>= \case
        Nothing -> do
          logAttention "embed: effect has no configured space" (object [])
          liftIO (threadDelay errorMicros)
        Just space ->
          withMaintenanceLease EmbeddingMaintenance owner embeddingLeaseSeconds (tick space) >>= \case
            MaintenanceUnavailable -> liftIO (threadDelay idleMicros)
            MaintenanceCompleted () -> pure ()
            MaintenanceLeaseLost ->
              logAttention "embed: maintenance lease lost; cancelled tick" (object [])

    -- Two questions with very different costs, joined by an OR that made
    -- both pay the expensive one.  It was redundant as well: a row with no
    -- embedding has no embedding_model either (the
    -- messages_embedding_metadata_consistent CHECK enforces it), so
    -- @embedding IS NULL@ was already contained in @embedding_model IS
    -- DISTINCT FROM ?@.  The disjunction bought nothing and cost the index —
    -- a parallel sequential scan of the whole table, 14,754 times in eleven
    -- days, to answer "nothing to do".
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

    tick space lease = do
      -- Recent-first so fresh messages become searchable immediately
      -- while the historical backfill trickles along behind.
      let modelId = space.esModelId
      msgs <- pendingMessages modelId
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
              \ WHERE message_id = ? AND rendered_text = ? \
              \   AND EXISTS (SELECT 1 FROM maintenance_leases ml \
              \     WHERE ml.domain = ? AND ml.owner = ? AND ml.fencing_token = ? AND ml.expires_at > now())"
              lease
              msgs
          okR <- embedMemories lease mems
          okE <-
            embedInto
              "UPDATE conversation_compartments SET embedding = ?::vector, embedding_model = ?, \
              \ embedding_dimensions = ?, embedding_content_hash = ?, embedding_updated_at = now() \
              \ WHERE id = ? AND summary_p1 = ? AND state = 'active' \
              \   AND EXISTS (SELECT 1 FROM maintenance_leases ml \
              \     WHERE ml.domain = ? AND ml.owner = ? AND ml.fencing_token = ? AND ml.expires_at > now())"
              lease
              episodes
          okS <-
            embedInto
              "UPDATE stickers SET embedding = ?::vector, embedding_model = ?, \
              \ embedding_dimensions = ?, embedding_content_hash = ?, embedding_updated_at = now() \
              \ WHERE sha256 = ? AND description = ? \
              \   AND EXISTS (SELECT 1 FROM maintenance_leases ml \
              \     WHERE ml.domain = ? AND ml.owner = ? AND ml.fencing_token = ? AND ml.expires_at > now())"
              lease
              stickers
          unless (okM && okR && okE && okS) $ liftIO (threadDelay errorMicros)
          liftIO (threadDelay busyMicros)

    -- Embed one batch and write vectors back; False on API failure
    -- (rows stay NULL for retry).  Polymorphic in the key column
    -- (messages/memories use bigint ids, stickers their sha256 text).
    embedInto :: (ToField i) => Query -> MaintenanceLease -> [(i, Text)] -> Eff es Bool
    embedInto _ _ [] = pure True
    embedInto sql lease rows = do
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
                      source,
                      maintenanceDomainText lease.mlDomain,
                      lease.mlOwner,
                      lease.mlFencingToken
                    )
              )
              (zip3 ids texts records)
          let stored = sum written
          logInfo "embed: batch done" $
            object ["rows" .= length ids, "stored" .= stored, "stale" .= (fromIntegral (length ids) - stored)]
          pure True

    embedMemories :: MaintenanceLease -> [PendingMemoryEmbedding] -> Eff es Bool
    embedMemories _ [] = pure True
    embedMemories lease pending = do
      let rows = take batchSize pending
          texts = map (.pendingMemoryContent) rows
      eres <- embedBatch (map (T.take 2000) texts)
      case eres of
        Left fault -> do
          logAttention "embed: memory batch failed" $
            object ["error" .= renderEmbeddingFault fault, "rows" .= length rows]
          pure False
        Right records -> do
          written <- traverse (uncurry (markPendingMemoryEmbeddedFenced lease)) (zip rows records)
          let stored = length (filter id written)
          logInfo "embed: memory batch done" $
            object ["rows" .= length rows, "stored" .= stored, "stale" .= (length rows - stored)]
          pure True

embeddingLeaseSeconds :: Int
embeddingLeaseSeconds = 300
