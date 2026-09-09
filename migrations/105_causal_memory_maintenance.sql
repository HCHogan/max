-- Independent, exact human citations. A maintenance note, retrieval hit,
-- paraphrase by Max, or broad episode range is not a new observation.
CREATE VIEW memory_human_sources AS
WITH citations AS (
  SELECT memory_id,memory_version,source_canonical_message_id AS message_id,source_conversation_id AS legacy_group
  FROM memory_evidence WHERE evidence_kind='message'
  UNION
  SELECT proposal.memory_id,proposal.memory_version,unnest(proposal.evidence_message_ids),capture.conversation_id
  FROM episode_memory_proposals proposal JOIN episode_capture_runs capture ON capture.id=proposal.capture_run_id
  WHERE proposal.outcome='applied'
  UNION
  SELECT review.memory_id,review.memory_version,(jsonb_array_elements_text(review.proposal->'evidence_message_ids'))::bigint,capture.conversation_id
  FROM episode_memory_reviews review JOIN episode_capture_runs capture ON capture.id=review.capture_run_id
  WHERE review.outcome='applied'
)
SELECT DISTINCT citation.memory_id,citation.memory_version,message.canonical_message_id AS message_id,
  message.group_id AS legacy_group,message.author_principal_id,message.ingest_seq,message.received_at,message.rendered_text
FROM citations citation JOIN messages message ON message.canonical_message_id=citation.message_id
WHERE message.group_id=citation.legacy_group AND message.user_id<>message.self_id
  AND NOT message.is_synthetic AND message.kind='chat' AND message.message_origin IN ('inbound','legacy')
  AND message.agent_turn_id IS NULL
  AND NOT EXISTS(SELECT 1 FROM message_relations relation WHERE relation.canonical_message_id=message.canonical_message_id AND relation.relation_kind='contained_in');

CREATE TABLE memory_maintenance_events (
  event_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  memory_id bigint NOT NULL,
  memory_version bigint NOT NULL,
  source_message_id bigint NOT NULL REFERENCES messages(canonical_message_id),
  created_at timestamptz NOT NULL DEFAULT now(),
  next_attempt_at timestamptz NOT NULL DEFAULT now(),
  attempts integer NOT NULL DEFAULT 0,
  finished_at timestamptz,
  outcome text,
  UNIQUE(memory_id,memory_version,source_message_id),
  FOREIGN KEY(memory_id,memory_version) REFERENCES memory_versions(memory_id,version)
);
CREATE INDEX memory_maintenance_pending ON memory_maintenance_events(next_attempt_at,event_id) WHERE finished_at IS NULL;

CREATE TABLE memory_expirations (
  memory_id bigint NOT NULL,
  memory_version bigint NOT NULL,
  source_message_id bigint NOT NULL REFERENCES messages(canonical_message_id),
  expires_on date NOT NULL,
  source_text_hash text NOT NULL,
  due_at timestamptz NOT NULL,
  reason text NOT NULL,
  finished_at timestamptz,
  outcome text,
  PRIMARY KEY(memory_id,memory_version),
  FOREIGN KEY(memory_id,memory_version) REFERENCES memory_versions(memory_id,version)
);
