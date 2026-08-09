-- ADR 005 E1: digest-tier turn continuity.
--
-- Prompt/catalog versions are facts about the environment in which a turn
-- ran.  They make ambient drift explicit without granting replay authority.
ALTER TABLE agent_turns
  ADD COLUMN prompt_major integer NOT NULL DEFAULT 1 CHECK (prompt_major > 0),
  ADD COLUMN tool_catalog_fingerprint text;

ALTER TABLE agent_turns
  ADD CONSTRAINT agent_turns_tool_catalog_fingerprint_check
    CHECK (tool_catalog_fingerprint IS NULL OR tool_catalog_fingerprint ~ '^[0-9a-f]{64}$'),
  ADD CONSTRAINT agent_turns_turn_conversation_unique UNIQUE (turn_id, conversation_id);

-- A continuation is always a new turn U consuming a finished turn T.  The
-- composite foreign keys make a cross-conversation edge unrepresentable.
CREATE TABLE turn_edges (
  edge_id bigserial PRIMARY KEY,
  conversation_id bigint NOT NULL REFERENCES conversations(conversation_id) ON DELETE CASCADE,
  from_turn_id bigint NOT NULL,
  to_turn_id bigint NOT NULL,
  edge_kind text NOT NULL CHECK (edge_kind = 'fork-from'),
  created_by bigint REFERENCES principals(principal_id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT turn_edges_distinct_turns CHECK (from_turn_id <> to_turn_id),
  CONSTRAINT turn_edges_from_scope_fk
    FOREIGN KEY (from_turn_id, conversation_id)
    REFERENCES agent_turns(turn_id, conversation_id) ON DELETE CASCADE,
  CONSTRAINT turn_edges_to_scope_fk
    FOREIGN KEY (to_turn_id, conversation_id)
    REFERENCES agent_turns(turn_id, conversation_id) ON DELETE CASCADE,
  UNIQUE (from_turn_id, to_turn_id, edge_kind)
);

CREATE INDEX turn_edges_from_idx
  ON turn_edges (conversation_id, from_turn_id, created_at DESC);

CREATE INDEX turn_edges_to_idx
  ON turn_edges (conversation_id, to_turn_id, created_at DESC);
