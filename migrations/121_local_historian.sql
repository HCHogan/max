-- Summaries, memory proposals and completed captures remain business history.
-- Interrupted captures are not resumed; canonical gaps supply fresh work.
UPDATE episode_capture_runs
SET status='abandoned',lease_owner=NULL,lease_expires_at=NULL,next_retry_at=NULL,
    last_error=COALESCE(last_error,'historian execution retired; source history retained'),updated_at=now()
WHERE status IN ('pending','leased','generated');
UPDATE episode_capture_runs SET next_retry_at=NULL WHERE next_retry_at IS NOT NULL;
DROP INDEX episode_capture_claim_idx;
DROP INDEX episode_capture_one_open_rebuild_idx;
ALTER TABLE episode_capture_runs ALTER COLUMN idempotency_key DROP NOT NULL;
