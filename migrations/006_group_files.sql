-- Catalog of non-image files received via group messages.  Images
-- live in their own 'images' / 'message_images' tables (Phase 3);
-- this is the analogue for everything else (.pdf, .zip, .csv,
-- whatever someone drops into the group).
--
-- file_id is QQ's identifier for the upload; sha256 is the content
-- hash after we fetch.  local_path mirrors the images convention:
-- relative to AppConfig.imagesDir (var/blobs going forward — see the
-- shared content-addressed store).
CREATE TABLE group_files (
    file_id           text     PRIMARY KEY,
    group_id          bigint   NOT NULL,
    message_id        bigint,                       -- nullable; notice-only uploads have no message_id
    sender_user_id    bigint   NOT NULL,
    file_name         text     NOT NULL,
    mime_type         text,
    bytes_size        bigint,
    sha256            text,                         -- nullable until download completes
    local_path        text,                         -- nullable until stored
    received_at       timestamptz NOT NULL DEFAULT now(),
    fetched_at        timestamptz                   -- nullable until fetched
);

CREATE INDEX group_files_group_received_idx
    ON group_files (group_id, received_at DESC);

CREATE INDEX group_files_sha256_idx
    ON group_files (sha256)
    WHERE sha256 IS NOT NULL;
