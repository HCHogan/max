-- Memory-extraction watermark: everything up to this instant has been
-- through (or deliberately skipped by) the episode extractor.  NULL =
-- never extracted; the boot recovery pass arms a timer for any group
-- with chat newer than its anchor, so an extraction lost to a restart
-- is caught up instead of dropped.
ALTER TABLE sessions ADD COLUMN memx_anchor timestamptz;
