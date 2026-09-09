-- Candidate instructions have no authority. Nothing is advertised until an
-- operator imports a passing paired replay against a later completed task.
CREATE TABLE task_experience_candidates (
  candidate_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  task_id bigint NOT NULL REFERENCES durable_tasks(task_id),
  task_revision integer NOT NULL,
  legacy_group bigint NOT NULL,
  source_fingerprint text NOT NULL,
  capsule jsonb NOT NULL,
  capsule_fingerprint text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  published_skill_id bigint REFERENCES skills(id) ON DELETE SET NULL,
  invalidated_at timestamptz,
  invalidation_reason text,
  UNIQUE(task_id,task_revision)
);
CREATE TABLE task_experience_runs (
  task_id bigint NOT NULL REFERENCES durable_tasks(task_id),
  task_revision integer NOT NULL,
  attempts integer NOT NULL DEFAULT 0,
  next_attempt_at timestamptz NOT NULL DEFAULT now(),
  last_error text,
  PRIMARY KEY(task_id,task_revision)
);
CREATE TABLE task_experience_replays (
  replay_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  candidate_id bigint NOT NULL REFERENCES task_experience_candidates(candidate_id),
  later_task_id bigint NOT NULL REFERENCES durable_tasks(task_id),
  later_task_revision integer NOT NULL,
  later_fingerprint text NOT NULL,
  capsule_fingerprint text NOT NULL,
  report jsonb NOT NULL,
  passed boolean NOT NULL,
  reviewer text NOT NULL CHECK(length(trim(reviewer))>0),
  validated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TRIGGER task_experience_replays_immutable BEFORE UPDATE OR DELETE ON task_experience_replays
FOR EACH ROW EXECUTE FUNCTION reject_operational_review_mutation();
