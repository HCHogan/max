-- What the official QQ bot needs besides: a second id to quote a message
-- by, and the gateway session to resume after a restart. See "QQ 官方机器人".

-- The platform's id for quoting a row, where it isn't native_id: QQ's
-- msg_idx for someone's message, the ref_idx QQ gave back for one Max sent.
alter table messages add column quote_id text;
create index on messages (endpoint_id, quote_id) where quote_id is not null;
alter table deliveries add column quote_id text;
create index on deliveries (endpoint_id, quote_id) where quote_id is not null;

-- A platform connection's session, saved as Max stops, so that the next
-- start resumes it and the platform replays what came in between.
create table gateway_sessions (
    platform text primary key check (platform in ('qq')),
    session_id text not null,
    seq bigint not null,
    saved_at timestamptz not null
);
