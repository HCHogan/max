-- The historian is gone, and with it the switch 0021 added. Its tables,
-- summaries, summary_runs and summary_embeddings, stay with their rows,
-- and so do the old usage rows of purpose historian. See "摘要" in
-- docs/rust-rewrite.md.
alter table conversation_settings drop column historian;
