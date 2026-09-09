-- Rebuildable prompt projection only; journal/task state remains authoritative.
CREATE TABLE turn_working_context (
  checkpoint_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  turn_id bigint NOT NULL REFERENCES agent_turns(turn_id),
  summary text NOT NULL CHECK(length(summary)<=8000),
  input_tokens integer NOT NULL CHECK(input_tokens>=0),
  input_limit integer NOT NULL CHECK(input_limit>=0),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX turn_working_context_latest ON turn_working_context(turn_id,checkpoint_id DESC);
