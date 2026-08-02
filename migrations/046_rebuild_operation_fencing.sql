-- One source compartment can have at most one retryable/open replacement.
-- A second admin click or process therefore observes the existing operation
-- instead of paying for a doomed duplicate Historian call.

CREATE UNIQUE INDEX episode_capture_one_open_rebuild_idx
    ON episode_capture_runs (replaces_compartment_id)
    WHERE replaces_compartment_id IS NOT NULL
      AND status IN ('pending', 'leased', 'generated', 'failed');
