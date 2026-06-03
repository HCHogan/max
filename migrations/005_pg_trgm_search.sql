-- Postgres's built-in 'simple' text-search config tokenises on
-- whitespace + ASCII punctuation only, so CJK-and-ASCII jammed
-- together ("提过haskell") becomes ONE token and `tsvector @@
-- plainto_tsquery('simple', 'haskell')` misses it.  pg_trgm's GIN
-- index makes ILIKE substring queries fast enough to use as the
-- search backend without a real tokeniser.
CREATE EXTENSION IF NOT EXISTS pg_trgm;

CREATE INDEX IF NOT EXISTS messages_rendered_text_trgm
    ON messages USING gin (rendered_text gin_trgm_ops);

-- The generated 'rendered_text_tsv' column stays for now (harmless,
-- might be useful if we ever bolt on a real CJK tokeniser like
-- zhparser).  Phase 6c+ may drop it.
