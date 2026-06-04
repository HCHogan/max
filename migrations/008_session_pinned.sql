-- Pinned messages: explicit "include these regardless of watermark"
-- per session.  Stored as a JSON array of message_ids.
ALTER TABLE sessions
    ADD COLUMN pinned jsonb NOT NULL DEFAULT '[]'::jsonb;

-- The 'history' column is no longer the source of truth — mention
-- history is reconstructed from the 'messages' table at dispatch
-- time.  Drop it; outbound bot replies persisted by the new
-- dispatchLLM path are what carry the assistant turns now.
ALTER TABLE sessions
    DROP COLUMN history;
