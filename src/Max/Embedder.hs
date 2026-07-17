-- |
-- Background embedding worker: polls for rows whose @embedding@ is
-- still NULL (new group messages, new/edited memories, freshly
-- captioned stickers), embeds them in batches through
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
import Data.Foldable (traverse_)
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as T
import Effectful
import Effectful.Log
import Database.PostgreSQL.Simple (Query)
import Database.PostgreSQL.Simple.ToField (ToField)
import Effectful.PostgreSQL (WithConnection, execute, query_)
import Max.Embedding (EmbedClient, embedTexts, renderVector)
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
  (WithConnection :> es, Log :> es, IOE :> es) =>
  EmbedClient ->
  Eff es ()
embedWorker client = forever $ do
  tick `catchSync` \e -> do
    logAttention "embed: tick crashed" $ object ["error" .= T.pack (show e)]
    liftIO (threadDelay errorMicros)
  where
    tick = do
      -- Recent-first so fresh messages become searchable immediately
      -- while the historical backfill trickles along behind.
      msgs <-
        query_
          "SELECT message_id, rendered_text FROM messages \
          \ WHERE embedding IS NULL \
          \   AND NOT is_synthetic \
          \   AND char_length(rendered_text) >= 4 \
          \ ORDER BY received_at DESC LIMIT 64"
      mems <-
        query_
          "SELECT id, content FROM memories WHERE embedding IS NULL LIMIT 64"
      -- Stickers embed their vision caption (the retrieval key for
      -- send_sticker); rows wait here until the caption worker fills
      -- description in.
      stickers <-
        query_
          "SELECT sha256, description FROM stickers \
          \ WHERE embedding IS NULL AND description IS NOT NULL AND NOT banned \
          \ LIMIT 64"
      if null (msgs :: [(Int64, Text)])
        && null (mems :: [(Int64, Text)])
        && null (stickers :: [(Text, Text)])
        then liftIO (threadDelay idleMicros)
        else do
          okM <- embedInto "UPDATE messages SET embedding = ?::vector WHERE message_id = ?" msgs
          okR <- embedInto "UPDATE memories SET embedding = ?::vector WHERE id = ?" mems
          okS <- embedInto "UPDATE stickers SET embedding = ?::vector WHERE sha256 = ?" stickers
          unless (okM && okR && okS) $ liftIO (threadDelay errorMicros)
          liftIO (threadDelay busyMicros)

    -- Embed one batch and write vectors back; False on API failure
    -- (rows stay NULL for retry).  Polymorphic in the key column
    -- (messages/memories use bigint ids, stickers their sha256 text).
    embedInto :: ToField i => Query -> [(i, Text)] -> Eff es Bool
    embedInto _ [] = pure True
    embedInto sql rows = do
      let (ids, texts) = unzip (take batchSize rows)
      eres <- liftIO (embedTexts client (map (T.take 2000) texts))
      case eres of
        Left err -> do
          logAttention "embed: batch failed" $
            object ["error" .= err, "rows" .= length ids]
          pure False
        Right vecs -> do
          traverse_
            (\(i, v) -> execute sql (renderVector v, i))
            (zip ids vecs)
          logInfo "embed: batch done" $ object ["rows" .= length ids]
          pure True
