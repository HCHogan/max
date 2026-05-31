CREATE SEQUENCE synthetic_message_id_seq
    MINVALUE 1
    MAXVALUE 9223372036854775807
    START WITH 1;

ALTER TABLE messages
    ADD COLUMN original_message_id bigint,
    ADD COLUMN original_sent_at    timestamptz;

CREATE INDEX messages_original_id_idx ON messages (original_message_id);
