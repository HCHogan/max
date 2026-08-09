-- Shared durability substrate for ADR 002/005.
--
-- A process-local Max.Tasks.TaskId remains the operator handle used by !ps
-- and !kill.  agent_turns is the durable, conversation-scoped identity used
-- by the journal and by the model-facing t# namespace.
CREATE TABLE agent_turns (
  turn_id bigserial PRIMARY KEY,
  conversation_id bigint NOT NULL REFERENCES conversations(conversation_id) ON DELETE CASCADE,
  turn_ordinal bigint NOT NULL CHECK (turn_ordinal > 0),
  trigger_canonical_message_id bigint REFERENCES messages(canonical_message_id) ON DELETE SET NULL,
  initiator_principal_id bigint REFERENCES principals(principal_id) ON DELETE SET NULL,
  status text NOT NULL,
  profile text,
  started_at timestamptz NOT NULL DEFAULT now(),
  finished_at timestamptz,
  llm_turns integer NOT NULL DEFAULT 0 CHECK (llm_turns >= 0),
  prompt_tokens bigint NOT NULL DEFAULT 0 CHECK (prompt_tokens >= 0),
  completion_tokens bigint NOT NULL DEFAULT 0 CHECK (completion_tokens >= 0),
  cached_prompt_tokens bigint NOT NULL DEFAULT 0 CHECK (cached_prompt_tokens >= 0),
  abort_reason text,
  recovery_owner text,
  recovery_claimed_at timestamptz,
  trace_archive_sha256 text,
  trace_archive_size_bytes bigint CHECK (trace_archive_size_bytes IS NULL OR trace_archive_size_bytes >= 0),
  trace_archive_created_at timestamptz,
  trace_archive_expires_at timestamptz,
  CONSTRAINT agent_turns_status_check
    CHECK (status = ANY (ARRAY['starting'::text, 'running'::text, 'succeeded'::text,
                               'silence'::text, 'failed'::text, 'aborted'::text,
                               'crashed'::text, 'recovery-pending'::text])),
  CONSTRAINT agent_turns_archive_lifecycle_check
    CHECK (
      (trace_archive_sha256 IS NULL AND trace_archive_size_bytes IS NULL
       AND trace_archive_created_at IS NULL AND trace_archive_expires_at IS NULL)
      OR
      (trace_archive_sha256 IS NOT NULL AND trace_archive_size_bytes IS NOT NULL
       AND trace_archive_created_at IS NOT NULL AND trace_archive_expires_at IS NOT NULL)
    ),
  CONSTRAINT agent_turns_archive_sha_check
    CHECK (trace_archive_sha256 IS NULL OR trace_archive_sha256 ~ '^[0-9a-f]{64}$'),
  UNIQUE (conversation_id, turn_ordinal)
);

CREATE INDEX agent_turns_recent_idx
  ON agent_turns (conversation_id, started_at DESC, turn_id DESC);

CREATE INDEX agent_turns_active_idx
  ON agent_turns (conversation_id, turn_id)
  WHERE status = ANY (ARRAY['starting'::text, 'running'::text, 'recovery-pending'::text]);

-- L3 send linkage.  A chunk index is allocated before publication and is
-- unique inside a turn; failed publications may therefore leave harmless
-- gaps, but a committed canonical message can never be linked twice.
ALTER TABLE messages
  ADD COLUMN agent_turn_id bigint REFERENCES agent_turns(turn_id) ON DELETE SET NULL,
  ADD COLUMN turn_chunk_index integer;

ALTER TABLE messages
  ADD CONSTRAINT messages_turn_output_pair_check
    CHECK ((agent_turn_id IS NULL) = (turn_chunk_index IS NULL)),
  ADD CONSTRAINT messages_turn_chunk_index_check
    CHECK (turn_chunk_index IS NULL OR turn_chunk_index >= 0);

CREATE UNIQUE INDEX messages_turn_output_idx
  ON messages (agent_turn_id, turn_chunk_index)
  WHERE agent_turn_id IS NOT NULL;

-- Normalized horizon-1 execution events.  journal_id is deliberately not a
-- model handle; t#<turn_ordinal>:r<execution_ordinal> is the scoped alternate
-- key.  Result blobs are internal storage metadata and are never rendered to
-- the model.
CREATE TABLE execution_journal (
  journal_id bigserial PRIMARY KEY,
  turn_id bigint NOT NULL REFERENCES agent_turns(turn_id) ON DELETE CASCADE,
  execution_ordinal bigint NOT NULL CHECK (execution_ordinal > 0),
  node_id text NOT NULL,
  plan_hash text,
  event_kind text NOT NULL,
  state text NOT NULL,
  call_id text,
  tool_ref text,
  schema_version integer,
  schema_hash text,
  normalized_input jsonb,
  effect_labels jsonb NOT NULL DEFAULT '[]'::jsonb,
  retry_class text,
  idempotency_key text,
  guard_decision jsonb,
  elaboration_reason text,
  failure_code text,
  failure_detail text,
  result_inline jsonb,
  result_blob_sha256 text,
  result_size_bytes bigint CHECK (result_size_bytes IS NULL OR result_size_bytes >= 0),
  result_preview text,
  observed_manifest jsonb,
  output_canonical_message_id bigint REFERENCES messages(canonical_message_id) ON DELETE SET NULL,
  started_at timestamptz NOT NULL DEFAULT now(),
  finished_at timestamptz,
  CONSTRAINT execution_journal_event_kind_check
    CHECK (event_kind = ANY (ARRAY['tool_call'::text, 'model_note'::text, 'trigger_input'::text])),
  CONSTRAINT execution_journal_state_check
    CHECK (state = ANY (ARRAY['started'::text, 'rejected'::text, 'succeeded'::text,
                              'failed'::text, 'committed'::text, 'outcome-unknown'::text])),
  CONSTRAINT execution_journal_effect_labels_array_check
    CHECK (jsonb_typeof(effect_labels) = 'array'::text),
  CONSTRAINT execution_journal_observed_manifest_check
    CHECK (observed_manifest IS NULL OR jsonb_typeof(observed_manifest) = 'object'::text),
  CONSTRAINT execution_journal_result_sha_check
    CHECK (result_blob_sha256 IS NULL OR result_blob_sha256 ~ '^[0-9a-f]{64}$'),
  CONSTRAINT execution_journal_plan_hash_check
    CHECK (plan_hash IS NULL OR plan_hash ~ '^[0-9a-f]{64}$'),
  CONSTRAINT execution_journal_result_storage_check
    CHECK (NOT (result_inline IS NOT NULL AND result_blob_sha256 IS NOT NULL)),
  UNIQUE (turn_id, execution_ordinal)
);

CREATE INDEX execution_journal_turn_idx
  ON execution_journal (turn_id, execution_ordinal);

CREATE INDEX execution_journal_unknown_idx
  ON execution_journal (turn_id, journal_id)
  WHERE state = ANY (ARRAY['started'::text, 'outcome-unknown'::text]);

-- Durable sandbox metadata.  The named volume is the current state; this row
-- is its authoritative lifecycle record and the in-memory registry is only a
-- cache/lock table.  Container loss is repairable from image + volume.
CREATE TABLE sandboxes (
  sandbox_id bigserial PRIMARY KEY,
  conversation_id bigint NOT NULL REFERENCES conversations(conversation_id) ON DELETE CASCADE,
  sandbox_handle text NOT NULL UNIQUE,
  container_name text NOT NULL UNIQUE,
  volume_name text NOT NULL UNIQUE,
  image text NOT NULL,
  network_mode text NOT NULL CHECK (network_mode = ANY (ARRAY['bridge'::text, 'none'::text])),
  status text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  last_used_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL DEFAULT (now() + interval '14 days'),
  destroyed_at timestamptz,
  failure_detail text,
  CONSTRAINT sandboxes_handle_check CHECK (sandbox_handle ~ '^s[1-9][0-9]*$'),
  CONSTRAINT sandboxes_status_check
    CHECK (status = ANY (ARRAY['creating'::text, 'active'::text,
                               'outcome-unknown'::text, 'destroying'::text,
                               'destroyed'::text]))
);

CREATE INDEX sandboxes_active_conversation_idx
  ON sandboxes (conversation_id, sandbox_id)
  WHERE status <> 'destroyed';

CREATE INDEX sandboxes_expiry_idx
  ON sandboxes (expires_at, sandbox_id)
  WHERE status = 'active';
