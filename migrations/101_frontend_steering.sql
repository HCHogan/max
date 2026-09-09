-- Durable input ownership only; routing and settlement policy live in Haskell.
ALTER TABLE conversation_frontends ADD COLUMN accepting_input boolean NOT NULL DEFAULT true;

CREATE TABLE frontend_inputs (
  input_id bigserial PRIMARY KEY,
  turn_id bigint NOT NULL REFERENCES agent_turns ON DELETE CASCADE,
  message_id bigint NOT NULL REFERENCES messages(canonical_message_id) ON DELETE CASCADE,
  kind text NOT NULL CHECK (kind IN ('steering', 'message')),
  seen_at timestamptz,
  disposition text CHECK (disposition IN ('answered', 'waiting', 'declined')),
  released_at timestamptz,
  UNIQUE (turn_id, message_id)
);
CREATE UNIQUE INDEX frontend_inputs_active_message ON frontend_inputs(message_id) WHERE released_at IS NULL;
CREATE INDEX frontend_inputs_pending ON frontend_inputs(turn_id, input_id) WHERE released_at IS NULL;
