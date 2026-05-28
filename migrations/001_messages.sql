CREATE TABLE messages (
    message_id              bigint  PRIMARY KEY,
    group_id                bigint  NOT NULL,
    user_id                 bigint  NOT NULL,
    self_id                 bigint  NOT NULL,
    received_at             timestamptz NOT NULL DEFAULT now(),

    segments                jsonb   NOT NULL,
    rendered_text           text    NOT NULL,
    raw_message             text    NOT NULL DEFAULT '',

    sender_nickname         text,
    sender_card             text,

    reply_to_message_id     bigint,
    forwarded_in_message_id bigint REFERENCES messages(message_id) ON DELETE SET NULL,
    forward_position        int,
    is_synthetic            boolean NOT NULL DEFAULT false,

    rendered_text_tsv       tsvector GENERATED ALWAYS AS (to_tsvector('simple', rendered_text)) STORED
);

CREATE INDEX messages_group_received_idx ON messages (group_id, received_at DESC);
CREATE INDEX messages_user_idx           ON messages (user_id);
CREATE INDEX messages_reply_idx          ON messages (reply_to_message_id);
CREATE INDEX messages_forward_in_idx     ON messages (forwarded_in_message_id);
CREATE INDEX messages_text_idx           ON messages USING GIN (rendered_text_tsv);
