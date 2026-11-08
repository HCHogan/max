-- The limits a conversation sets for itself, with `/config` or Max's
-- `config` tool: `max_core::limits::Overrides` as JSON, a key per one set.
-- See "Settings a conversation sets" in docs/rust-rewrite.md.
alter table conversation_settings add column overrides jsonb not null default '{}';
