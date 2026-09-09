-- Summary publication and memory repair have separate lifecycles. The original
-- proposal and its outcome remain evidence; reviewed proposals use fresh CAS.
CREATE TABLE episode_memory_reviews (
  review_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  capture_run_id bigint NOT NULL,
  proposal_index integer NOT NULL,
  proposal jsonb,
  outcome text NOT NULL CHECK (outcome IN ('applied','dismissed','rejected_validation','rejected_store')),
  outcome_reason text,
  memory_id bigint REFERENCES memories(id),
  memory_version bigint,
  actor text NOT NULL CHECK(length(trim(actor))>0),
  reason text NOT NULL CHECK(length(trim(reason))>0),
  reviewed_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  FOREIGN KEY (capture_run_id,proposal_index) REFERENCES episode_memory_proposals(capture_run_id,proposal_index)
);
CREATE INDEX episode_memory_review_latest ON episode_memory_reviews(capture_run_id,proposal_index,review_id DESC);
CREATE TRIGGER episode_memory_reviews_immutable BEFORE UPDATE OR DELETE ON episode_memory_reviews
FOR EACH ROW EXECUTE FUNCTION reject_operational_review_mutation();

CREATE VIEW episode_memory_review_queue AS
SELECT original.*,capture.conversation_id,COALESCE(review.outcome,'pending') AS review_state,review.review_id
FROM episode_memory_proposals original JOIN episode_capture_runs capture ON capture.id=original.capture_run_id
LEFT JOIN LATERAL (
  SELECT outcome,review_id FROM episode_memory_reviews r
  WHERE r.capture_run_id=original.capture_run_id AND r.proposal_index=original.proposal_index
  ORDER BY review_id DESC LIMIT 1
) review ON true
WHERE original.outcome IN ('rejected_store','rejected_validation')
  AND COALESCE(review.outcome,'pending') NOT IN ('applied','dismissed');
