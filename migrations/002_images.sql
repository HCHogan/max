CREATE TABLE images (
    sha256        text       PRIMARY KEY,
    mime_type     text       NOT NULL,
    bytes_size    bigint     NOT NULL,
    local_path    text       NOT NULL,
    width         int,
    height        int,
    first_seen_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE message_images (
    message_id bigint NOT NULL REFERENCES messages(message_id) ON DELETE CASCADE,
    sha256     text   NOT NULL REFERENCES images(sha256) ON DELETE RESTRICT,
    seg_index  int    NOT NULL,
    PRIMARY KEY (message_id, seg_index)
);

CREATE INDEX message_images_sha_idx ON message_images(sha256);
