-- !clear sets this to now() so future prompts skip any group ambient
-- message older than the watermark.  Nullable: NULL means "never
-- cleared" → no filtering, behaves as before.
ALTER TABLE sessions
    ADD COLUMN cleared_at timestamptz;
