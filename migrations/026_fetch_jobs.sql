-- Durable work list for inbound media: images, videos, forwarded-chat
-- chains, group files.
--
-- Before this, all of them rode in-memory TQueues.  The queue *was* the
-- only record that the work existed, so a restart — or any worker
-- crash, which 'link' turns into a process-wide exit — silently
-- dropped every pending download and nothing ever went back for them.
-- A picture the model was about to be asked about simply never arrived.
--
-- Same shape the embedder already uses (Max.Embedder polls for rows
-- whose embedding IS NULL), only made explicit: one row per fetch we
-- owe ourselves, deleted on success.  Boot recovery falls out for
-- free — the worker's first claim picks up whatever the last process
-- left behind, so there is no separate recovery path to rot.
--
-- payload is the job record verbatim (see Max.DB.FetchQueue); kind says
-- which worker owns the row and how to decode it.  dedupe_key is the
-- job's natural key, so re-ingesting a message — NapCat redelivers on
-- reconnect — doesn't queue the same download twice.
CREATE TABLE fetch_jobs (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    kind          text        NOT NULL,   -- 'image' | 'forward' | 'file'
    dedupe_key    text        NOT NULL,
    payload       jsonb       NOT NULL,
    enqueued_at   timestamptz NOT NULL DEFAULT now(),
    -- Bumped when a worker claims the row, not when one reports
    -- failure: a job that takes the process down with it still counts,
    -- so a poison payload can't crash-loop us forever.
    attempts      int         NOT NULL DEFAULT 0,
    -- Lease held by whoever is currently fetching.  A dead process
    -- leaves stale leases behind and they expire on their own, which is
    -- why boot needs no cleanup step.
    claimed_until timestamptz,
    last_error    text,
    -- Set once the attempt budget is spent.  The row stays — a dead
    -- image URL is worth being able to look up months later — but drops
    -- out of the index below, so a pile of them can never slow the
    -- claim query down.  Note the UNIQUE above: a parked job is not
    -- re-queued if the same message is redelivered, which is the point.
    parked_at     timestamptz,
    UNIQUE (kind, dedupe_key)
);

-- Exactly the claim query's predicate.  Deliberately keyed on a column
-- rather than an `attempts < N` literal: the ceiling then lives only in
-- Max.DB.FetchQueue, with no constant to keep in sync across two files.
CREATE INDEX fetch_jobs_pending_idx
    ON fetch_jobs (kind, id)
    WHERE parked_at IS NULL;
