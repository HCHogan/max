-- The tiered reader and exact ingest-sequence cursor are now the only context
-- lifecycle.  These timestamps belonged to the retired count watermark and
-- newest-N memory extractor; keeping them would invite accidental reuse.

ALTER TABLE sessions
    DROP COLUMN context_anchor,
    DROP COLUMN memx_anchor;

DELETE FROM conversation_cursors
WHERE cursor_name = 'memory_extract';
