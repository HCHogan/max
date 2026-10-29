-- The Haskell version's tables, with only the columns max-import reads,
-- under their names and types. old_rows.sql fills them with made-up rows.

create table platform_accounts (
    platform_account_id bigint primary key,
    platform text not null,
    native_account_id text not null
);

create table principals (
    principal_id bigint primary key,
    display_name text,
    created_at timestamptz not null default '2026-01-01 00:00+08'
);

create table principal_identities (
    principal_identity_id bigint primary key,
    principal_id bigint not null references principals,
    platform_account_id bigint not null references platform_accounts,
    native_user_id text not null,
    display_name text,
    created_at timestamptz not null default '2026-01-01 00:00+08'
);

create table conversations (
    conversation_id bigint primary key,
    conversation_kind text not null,
    title text,
    legacy_group_id bigint,
    created_at timestamptz not null default '2026-01-01 00:00+08'
);

create table conversation_endpoints (
    endpoint_id bigint primary key,
    conversation_id bigint not null references conversations,
    platform_account_id bigint not null references platform_accounts,
    native_conversation_id text not null,
    created_at timestamptz not null default '2026-01-01 00:00+08'
);

create table messages (
    canonical_message_id bigint primary key,
    conversation_id bigint not null,
    origin_endpoint_id bigint not null,
    author_principal_id bigint not null,
    source_platform text not null default 'qq',
    event_kind text not null default 'message',
    kind text not null default 'chat',
    message_origin text not null default 'inbound',
    is_synthetic boolean not null default false,
    rendered_text text not null default '',
    sender_nickname text,
    sender_card text,
    source_native_event_id text not null,
    occurred_at timestamptz not null,
    received_at timestamptz not null,
    reply_to_canonical_message_id bigint,
    canonical_content jsonb not null,
    segments jsonb not null default '[]',
    ingest_seq bigint not null
);

create table platform_events (
    platform_event_id bigint primary key,
    canonical_message_id bigint,
    event_kind text not null,
    raw_payload jsonb
);

create table message_relations (
    relation_id bigint primary key,
    canonical_message_id bigint not null,
    relation_kind text not null,
    target_canonical_message_id bigint,
    relation_position integer
);

create table conversation_compartments (
    id bigint primary key,
    conversation_id bigint not null,
    start_ingest_seq bigint not null,
    end_ingest_seq bigint not null,
    summary_p1 text,
    summary_p2 text,
    summary_p3 text,
    summary text not null,
    episode_kind text not null,
    importance double precision not null,
    state text not null,
    historian_profile text not null,
    created_at timestamptz not null,
    activated_at timestamptz
);

create table sessions (
    group_id bigint primary key,
    model text,
    persona text,
    updated_at timestamptz not null,
    cleared_at timestamptz,
    proactive_override boolean,
    effort_override text
);

create table images (
    sha256 text primary key,
    mime_type text not null,
    bytes_size bigint not null,
    first_seen_at timestamptz not null,
    description text
);

create table stickers (
    sha256 text primary key,
    description text,
    banned boolean not null default false,
    first_seen_at timestamptz not null
);

create table videos (
    sha256 text primary key,
    mime_type text not null,
    bytes_size bigint not null,
    first_seen_at timestamptz not null
);

create table group_files (
    file_id text primary key,
    mime_type text,
    bytes_size bigint,
    sha256 text,
    received_at timestamptz not null,
    canonical_message_id bigint
);

create table message_images (
    sha256 text not null,
    seg_index integer not null,
    canonical_message_id bigint not null
);

create table message_videos (
    seg_index integer not null,
    sha256 text not null,
    canonical_message_id bigint not null
);
