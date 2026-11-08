-- `/stop` and `/start`: a stopped conversation still records every
-- message, but nothing in it starts a turn, and its programs can't post.
-- See "Commands" in docs/rust-rewrite.md.
alter table conversation_settings add column stopped boolean not null default false;
