-- Videos download like images: content-addressed blobs in the same
-- store, linked to messages via their own pair of tables (kept apart
-- from images so vision/image queries never sweep in videos).

CREATE TABLE videos (
    sha256        text        PRIMARY KEY,
    mime_type     text        NOT NULL,
    bytes_size    bigint      NOT NULL,
    local_path    text        NOT NULL,   -- relative to the blob root
    first_seen_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE message_videos (
    message_id bigint NOT NULL REFERENCES messages(message_id) ON DELETE CASCADE,
    seg_index  int    NOT NULL,
    sha256     text   NOT NULL REFERENCES videos(sha256),
    PRIMARY KEY (message_id, seg_index)
);

CREATE INDEX message_videos_sha256_idx ON message_videos (sha256);
