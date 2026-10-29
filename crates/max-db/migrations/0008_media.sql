-- Media in the content store, by the SHA-256 of its bytes; see "媒体".
-- What kind of media it is belongs to the message's node: the same bytes
-- can be a picture in one message and a sticker in another.
create table media (
    sha256 text primary key check (sha256 ~ '^[0-9a-f]{64}$'),
    mime text,
    size bigint not null check (size >= 0),
    width integer,
    height integer,
    first_seen_at timestamptz not null,
    -- The copy the model is sent, made once; the same sha256 when the
    -- original is small enough.
    model_sha256 text check (model_sha256 ~ '^[0-9a-f]{64}$'),
    -- Null until written; empty when the caption worker gave up.
    caption text,
    caption_model text
);

-- The downloaded media of a message: its n-th media node, from 0.
create table message_media (
    message_id bigint not null references messages,
    ordinal smallint not null check (ordinal >= 0),
    sha256 text not null references media,
    primary key (message_id, ordinal)
);

create index on message_media (sha256);
