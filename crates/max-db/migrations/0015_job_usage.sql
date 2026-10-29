-- Background agents' model calls; see "后台 agent" in docs/rust-rewrite.md.
alter table llm_usage drop constraint llm_usage_purpose_check;
alter table llm_usage add constraint llm_usage_purpose_check
    check (purpose in ('turn', 'intent', 'historian', 'caption', 'job'));
