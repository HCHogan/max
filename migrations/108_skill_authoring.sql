-- Immutable content and evidence only; policy and promotion live in Haskell.
CREATE TABLE skill_drafts (
  group_id bigint NOT NULL,
  name text NOT NULL,
  revision bigint NOT NULL CHECK (revision > 0),
  content jsonb NOT NULL,
  created_by bigint NOT NULL,
  recorded_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (group_id, name, revision)
);
CREATE TABLE skill_validations (
  validation_id bigserial PRIMARY KEY,
  group_id bigint NOT NULL,
  name text NOT NULL,
  draft_revision bigint NOT NULL,
  context jsonb NOT NULL,
  report jsonb NOT NULL,
  recorded_at timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (group_id, name, draft_revision) REFERENCES skill_drafts ON DELETE CASCADE
);
CREATE INDEX skill_validations_draft ON skill_validations(group_id,name,draft_revision,validation_id DESC);
CREATE TABLE skill_publications (
  group_id bigint NOT NULL,
  name text NOT NULL,
  skill_revision bigint NOT NULL,
  draft_revision bigint NOT NULL,
  validation_id bigint NOT NULL REFERENCES skill_validations,
  skill_id bigint REFERENCES skills ON DELETE SET NULL,
  recorded_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (group_id, name, skill_revision),
  FOREIGN KEY (group_id, name, draft_revision) REFERENCES skill_drafts
);
