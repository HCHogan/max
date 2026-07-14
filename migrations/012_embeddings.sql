-- Vector search groundwork (pgvector; provisioned via devenv/nix).
--
-- Untyped `vector` columns on purpose: the dimension follows whatever
-- embedding model the config points at (bge-m3 = 1024, openai small =
-- 1536, ...), and exact scans over this data volume (tens of
-- thousands of short rows) are millisecond-cheap without an index.
-- When scale ever demands HNSW, migrate to a typed column then.
--
-- Rows are embedded asynchronously by the embed worker (embedding IS
-- NULL = not yet done / retry).  The partial index keeps the worker's
-- "what's left" poll cheap.
CREATE EXTENSION IF NOT EXISTS vector;

ALTER TABLE messages ADD COLUMN embedding vector;
ALTER TABLE memories ADD COLUMN embedding vector;

CREATE INDEX messages_unembedded_idx
    ON messages (received_at DESC)
    WHERE embedding IS NULL;
