-- Captions for ordinary chat media, mirroring stickers.description:
-- a background worker (Max.MediaCaption) describes recent images and
-- videos so history markers can read [image#<id>: <简介>] /
-- [video#<id>: <简介>] instead of an opaque handle — the model gets
-- to know what's behind a marker without spending a view_image /
-- view_video call (and without re-paying the base64 every dispatch).
--
-- Sticker images keep their own caption pipeline on the stickers
-- table; the media worker skips any sha registered there.

ALTER TABLE images ADD COLUMN description text;
ALTER TABLE images ADD COLUMN caption_attempts int NOT NULL DEFAULT 0;

ALTER TABLE videos ADD COLUMN description text;
ALTER TABLE videos ADD COLUMN caption_attempts int NOT NULL DEFAULT 0;

CREATE INDEX images_uncaptioned_idx
    ON images (first_seen_at)
    WHERE description IS NULL AND caption_attempts < 5;

CREATE INDEX videos_uncaptioned_idx
    ON videos (first_seen_at)
    WHERE description IS NULL AND caption_attempts < 5;
