-- Content and revision history only; package policy is implemented in Haskell.
ALTER TABLE skills ADD COLUMN revision bigint NOT NULL DEFAULT 1 CHECK (revision > 0);
ALTER TABLE skills ADD COLUMN package jsonb NOT NULL DEFAULT '{"dependencies":[],"workflows":{}}';

CREATE TABLE skill_versions (
  skill_id bigint NOT NULL REFERENCES skills(id) ON DELETE CASCADE,
  revision bigint NOT NULL,
  snapshot jsonb NOT NULL,
  recorded_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (skill_id, revision)
);
INSERT INTO skill_versions (skill_id, revision, snapshot)
SELECT id, revision, to_jsonb(skills) FROM skills;
