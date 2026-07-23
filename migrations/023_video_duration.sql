-- Real duration of stored videos, probed at ingest (ffprobe).  The
-- model's own duration perception from sampled frames is unreliable
-- (observed: a 29s clip read as "2.1秒"), so every video label the
-- prompt renders states the known duration instead of letting the
-- model guess.  NULL for rows ingested before this migration — labels
-- just omit the duration then.
ALTER TABLE videos ADD COLUMN duration_seconds double precision;
