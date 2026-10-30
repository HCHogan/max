-- Whether the historian summarizes the conversation and its summaries are
-- in the context: on for some groups, off for others, to compare the two.
-- See "摘要" in docs/rust-rewrite.md.
alter table conversation_settings add column historian boolean not null default false;
