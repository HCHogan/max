-- Decisions are immutable per ingested message. Definition updates are ordered
-- against ingest by the existing conversations row lock.
ALTER TABLE messages ADD COLUMN inbound_ignored boolean NOT NULL DEFAULT false;

CREATE TABLE message_hooks (
  conversation_id bigint NOT NULL REFERENCES conversations ON DELETE CASCADE,
  name text NOT NULL,
  revision integer NOT NULL CHECK (revision > 0),
  PRIMARY KEY (conversation_id, name)
);
CREATE TABLE message_hook_versions (
  conversation_id bigint NOT NULL,
  name text NOT NULL,
  revision integer NOT NULL CHECK (revision > 0),
  event text NOT NULL CHECK (event = 'message.inbound'),
  source text NOT NULL,
  config jsonb NOT NULL,
  enabled boolean NOT NULL,
  actor_principal_id bigint NOT NULL REFERENCES principals,
  effective_after_ingest_seq bigint NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (conversation_id, name, revision),
  FOREIGN KEY (conversation_id, name) REFERENCES message_hooks ON DELETE CASCADE
);
CREATE TABLE message_hook_runs (
  run_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  conversation_id bigint NOT NULL,
  name text NOT NULL,
  revision integer NOT NULL,
  canonical_message_id bigint NOT NULL REFERENCES messages ON DELETE CASCADE,
  outcome text NOT NULL CHECK (outcome IN ('pass', 'ignore', 'error')),
  reason text,
  elapsed_ms double precision NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (conversation_id, name, canonical_message_id),
  FOREIGN KEY (conversation_id, name, revision)
    REFERENCES message_hook_versions ON DELETE CASCADE
);
CREATE INDEX message_hook_runs_lookup ON message_hook_runs (conversation_id, name, run_id DESC);

-- Keep raw audit/transport storage separate from all agent-facing reads.
-- Children of ignored forwards and metadata about ignored messages are hidden
-- too. Ordinary replies remain visible; their quoted source is filtered on read.
CREATE VIEW agent_messages AS
SELECT m.* FROM messages m
WHERE NOT m.inbound_ignored
  AND NOT EXISTS (
    SELECT 1 FROM message_relations r JOIN messages parent
      ON parent.canonical_message_id=r.target_canonical_message_id
    WHERE r.canonical_message_id=m.canonical_message_id
      AND r.relation_kind IN ('contained_in', 'replace', 'reaction', 'redacts')
      AND parent.inbound_ignored
  );
