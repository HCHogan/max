-- A small stable integer handle for each sticker, so the LLM can pick
-- one to send by id (find_stickers returns ids; send_sticker takes an
-- id) instead of by free-text.  sha256 stays the primary key; this is
-- just a compact, model-friendly alias.  Existing rows are backfilled
-- with sequential ids by the identity column.
ALTER TABLE stickers
    ADD COLUMN id bigint GENERATED ALWAYS AS IDENTITY UNIQUE;
