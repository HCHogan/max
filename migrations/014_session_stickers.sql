-- Per-session sticker override, set by !sticker on/off.  NULL = follow
-- the config-level default (AppConfig.stickersEnabled).  When effective
-- sticker sending is on, the send_sticker tool is registered for the
-- dispatch so the model can post stickers from the learned library.
ALTER TABLE sessions
    ADD COLUMN sticker_override boolean;
