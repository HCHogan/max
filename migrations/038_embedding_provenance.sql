-- Embeddings are derived data.  Keep enough provenance beside every vector
-- to decide whether it is compatible with the configured model and whether
-- it still describes the current source text.
--
-- Existing vectors predate this metadata and cannot be identified safely.
-- Invalidate them during the migration; the background worker will rebuild
-- them with provenance instead of allowing mixed models/dimensions into a
-- pgvector distance expression.

ALTER TABLE messages
    ADD COLUMN embedding_model text,
    ADD COLUMN embedding_dimensions integer,
    ADD COLUMN embedding_content_hash text,
    ADD COLUMN embedding_updated_at timestamptz;

ALTER TABLE memories
    ADD COLUMN embedding_model text,
    ADD COLUMN embedding_dimensions integer,
    ADD COLUMN embedding_content_hash text,
    ADD COLUMN embedding_updated_at timestamptz;

ALTER TABLE stickers
    ADD COLUMN embedding_model text,
    ADD COLUMN embedding_dimensions integer,
    ADD COLUMN embedding_content_hash text,
    ADD COLUMN embedding_updated_at timestamptz;

UPDATE messages SET embedding = NULL WHERE embedding IS NOT NULL;
UPDATE memories SET embedding = NULL WHERE embedding IS NOT NULL;
UPDATE stickers SET embedding = NULL WHERE embedding IS NOT NULL;

ALTER TABLE messages
    ADD CONSTRAINT messages_embedding_metadata_consistent CHECK (
        (embedding IS NULL
         AND embedding_model IS NULL
         AND embedding_dimensions IS NULL
         AND embedding_content_hash IS NULL
         AND embedding_updated_at IS NULL)
        OR
        (embedding IS NOT NULL
         AND embedding_model IS NOT NULL
         AND embedding_dimensions IS NOT NULL
         AND embedding_dimensions > 0
         AND embedding_dimensions = vector_dims(embedding)
         AND embedding_content_hash IS NOT NULL
         AND embedding_content_hash ~ '^[0-9a-f]{64}$'
         AND embedding_updated_at IS NOT NULL)
    );

ALTER TABLE memories
    ADD CONSTRAINT memories_embedding_metadata_consistent CHECK (
        (embedding IS NULL
         AND embedding_model IS NULL
         AND embedding_dimensions IS NULL
         AND embedding_content_hash IS NULL
         AND embedding_updated_at IS NULL)
        OR
        (embedding IS NOT NULL
         AND embedding_model IS NOT NULL
         AND embedding_dimensions IS NOT NULL
         AND embedding_dimensions > 0
         AND embedding_dimensions = vector_dims(embedding)
         AND embedding_content_hash IS NOT NULL
         AND embedding_content_hash ~ '^[0-9a-f]{64}$'
         AND embedding_updated_at IS NOT NULL)
    );

ALTER TABLE stickers
    ADD CONSTRAINT stickers_embedding_metadata_consistent CHECK (
        (embedding IS NULL
         AND embedding_model IS NULL
         AND embedding_dimensions IS NULL
         AND embedding_content_hash IS NULL
         AND embedding_updated_at IS NULL)
        OR
        (embedding IS NOT NULL
         AND embedding_model IS NOT NULL
         AND embedding_dimensions IS NOT NULL
         AND embedding_dimensions > 0
         AND embedding_dimensions = vector_dims(embedding)
         AND embedding_content_hash IS NOT NULL
         AND embedding_content_hash ~ '^[0-9a-f]{64}$'
         AND embedding_updated_at IS NOT NULL)
    );

-- Make invalidation independent of which write path changes source text.
-- The trigger also protects future admin and migration code from leaving a
-- stale vector attached to edited content.
CREATE FUNCTION invalidate_embedding_on_source_change()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    -- Dynamic JSON field access lets the same trigger function serve tables
    -- whose source columns have different names.  Direct OLD.column access
    -- would be planned against every trigger's row type, even in a branch for
    -- a different TG_ARGV value.
    IF to_jsonb(OLD) -> TG_ARGV[0] IS DISTINCT FROM
       to_jsonb(NEW) -> TG_ARGV[0] THEN
        NEW.embedding := NULL;
        NEW.embedding_model := NULL;
        NEW.embedding_dimensions := NULL;
        NEW.embedding_content_hash := NULL;
        NEW.embedding_updated_at := NULL;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER messages_invalidate_embedding
BEFORE UPDATE OF rendered_text ON messages
FOR EACH ROW EXECUTE FUNCTION invalidate_embedding_on_source_change('rendered_text');

CREATE TRIGGER memories_invalidate_embedding
BEFORE UPDATE OF content ON memories
FOR EACH ROW EXECUTE FUNCTION invalidate_embedding_on_source_change('content');

CREATE TRIGGER stickers_invalidate_embedding
BEFORE UPDATE OF description ON stickers
FOR EACH ROW EXECUTE FUNCTION invalidate_embedding_on_source_change('description');
