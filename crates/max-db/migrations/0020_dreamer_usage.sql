-- The dreamer's model calls; see "记忆" in docs/rust-rewrite.md.
alter table llm_usage drop constraint llm_usage_purpose_check;
alter table llm_usage add constraint llm_usage_purpose_check
    check (purpose in ('turn', 'intent', 'historian', 'caption', 'job', 'dreamer'));
