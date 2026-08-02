-- Rebuildable, exact-range chronological context projection.  Capture runs are
-- durable jobs; compartments are immutable summary payloads whose active
-- ranges cannot overlap.  Raw messages remain the source of truth.

CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS btree_gist;

-- Canonical hash of every raw ledger row in one conversation/range.  The hash
-- includes rows that are not transcript-eligible so a cursor can never step
-- over a command/synthetic row without that fact being represented.
CREATE FUNCTION conversation_source_hash(
    source_conversation_id bigint,
    source_start_seq bigint,
    source_end_seq bigint
)
RETURNS text
LANGUAGE sql
STABLE
AS $$
    SELECT encode(
        digest(
            convert_to(
                COALESCE(
                    jsonb_agg(
                        jsonb_build_array(
                            m.ingest_seq,
                            m.message_id,
                            m.user_id,
                            m.self_id,
                            to_char(
                                m.received_at AT TIME ZONE 'UTC',
                                'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'
                            ),
                            m.segments,
                            m.rendered_text,
                            m.raw_message,
                            m.reply_to_message_id,
                            m.forwarded_in_message_id,
                            m.is_synthetic,
                            m.kind
                        ) ORDER BY m.ingest_seq
                    ),
                    '[]'::jsonb
                )::text,
                'UTF8'
            ),
            'sha256'
        ),
        'hex'
    )
    FROM messages AS m
    WHERE m.group_id = source_conversation_id
      AND m.ingest_seq BETWEEN source_start_seq AND source_end_seq;
$$;

CREATE TABLE episode_capture_runs (
    id                         bigserial   PRIMARY KEY,
    conversation_id            bigint      NOT NULL,
    expected_cursor_seq         bigint      NOT NULL CHECK (expected_cursor_seq >= 0),
    start_ingest_seq            bigint      NOT NULL CHECK (start_ingest_seq > 0),
    end_ingest_seq              bigint      NOT NULL CHECK (end_ingest_seq >= start_ingest_seq),
    source_hash                 text        NOT NULL CHECK (source_hash ~ '^[0-9a-f]{64}$'),
    source_message_count        integer     NOT NULL CHECK (source_message_count > 0),
    scheduling_reason           text        NOT NULL CHECK (
        scheduling_reason IN ('idle', 'volume', 'token_pressure', 'backfill', 'rebuild')
    ),
    status                      text        NOT NULL DEFAULT 'pending' CHECK (
        status IN ('pending', 'leased', 'generated', 'published', 'failed')
    ),
    attempt                     integer     NOT NULL DEFAULT 0 CHECK (attempt >= 0),
    lease_owner                 text,
    lease_expires_at            timestamptz,
    next_retry_at               timestamptz,
    last_error                  text,
    historian_profile           text        NOT NULL CHECK (historian_profile <> ''),
    prompt_version              text        NOT NULL CHECK (prompt_version <> ''),
    schema_version              integer     NOT NULL CHECK (schema_version > 0),
    idempotency_key             text        NOT NULL UNIQUE CHECK (idempotency_key ~ '^[0-9a-f]{64}$'),
    raw_output                  text,
    parsed_output               jsonb,
    validation_errors           jsonb        NOT NULL DEFAULT '[]'::jsonb,
    replaces_compartment_id     bigint,
    published_compartment_id    bigint,
    created_at                  timestamptz NOT NULL DEFAULT now(),
    updated_at                  timestamptz NOT NULL DEFAULT now(),
    published_at                timestamptz,
    CHECK (
        (status IN ('leased', 'generated') AND lease_owner IS NOT NULL AND lease_expires_at IS NOT NULL)
        OR
        (status NOT IN ('leased', 'generated'))
    )
);

CREATE INDEX episode_capture_claim_idx
    ON episode_capture_runs (COALESCE(next_retry_at, created_at), id)
    WHERE status IN ('pending', 'failed', 'leased', 'generated');

CREATE TABLE conversation_compartments (
    id                       bigserial   PRIMARY KEY,
    conversation_id          bigint      NOT NULL,
    capture_run_id            bigint      NOT NULL UNIQUE REFERENCES episode_capture_runs(id) ON DELETE RESTRICT,
    start_ingest_seq          bigint      NOT NULL CHECK (start_ingest_seq > 0),
    end_ingest_seq            bigint      NOT NULL CHECK (end_ingest_seq >= start_ingest_seq),
    source_range              int8range   GENERATED ALWAYS AS (
        int8range(start_ingest_seq, end_ingest_seq, '[]')
    ) STORED,
    source_hash               text        NOT NULL CHECK (source_hash ~ '^[0-9a-f]{64}$'),
    source_message_count      integer     NOT NULL CHECK (source_message_count > 0),
    summary_p1                text        NOT NULL CHECK (summary_p1 <> ''),
    summary_p2                text        NOT NULL CHECK (summary_p2 <> ''),
    summary_p3                text        NOT NULL CHECK (summary_p3 <> ''),
    episode_kind              text        NOT NULL CHECK (
        episode_kind IN ('max_interaction', 'ambient', 'mixed', 'decision', 'support', 'social')
    ),
    importance                double precision NOT NULL CHECK (importance BETWEEN 0 AND 1),
    confidence                double precision NOT NULL CHECK (confidence BETWEEN 0 AND 1),
    state                     text        NOT NULL DEFAULT 'staged' CHECK (
        state IN ('staged', 'active', 'superseded')
    ),
    superseded_by             bigint,
    historian_profile         text        NOT NULL,
    prompt_version            text        NOT NULL,
    schema_version            integer     NOT NULL CHECK (schema_version > 0),
    materialization_version   bigint      NOT NULL CHECK (materialization_version > 0),
    speaker_stats             jsonb        NOT NULL DEFAULT '{}'::jsonb,
    embedding                 vector,
    embedding_model           text,
    embedding_dimensions      integer,
    embedding_content_hash    text,
    embedding_updated_at      timestamptz,
    created_at                 timestamptz NOT NULL DEFAULT now(),
    activated_at               timestamptz,
    CHECK (
        (state = 'superseded' AND superseded_by IS NOT NULL AND superseded_by <> id)
        OR
        (state <> 'superseded' AND superseded_by IS NULL)
    ),
    CHECK (
        (embedding IS NULL
         AND embedding_model IS NULL
         AND embedding_dimensions IS NULL
         AND embedding_content_hash IS NULL
         AND embedding_updated_at IS NULL)
        OR
        (embedding IS NOT NULL
         AND embedding_model IS NOT NULL
         AND embedding_dimensions = vector_dims(embedding)
         AND embedding_content_hash ~ '^[0-9a-f]{64}$'
         AND embedding_updated_at IS NOT NULL)
    )
);

ALTER TABLE conversation_compartments
    ADD CONSTRAINT conversation_compartments_superseded_by_fkey
    FOREIGN KEY (superseded_by) REFERENCES conversation_compartments(id) ON DELETE RESTRICT;

ALTER TABLE episode_capture_runs
    ADD CONSTRAINT episode_capture_replaces_fkey
    FOREIGN KEY (replaces_compartment_id) REFERENCES conversation_compartments(id) ON DELETE RESTRICT,
    ADD CONSTRAINT episode_capture_published_fkey
    FOREIGN KEY (published_compartment_id) REFERENCES conversation_compartments(id) ON DELETE RESTRICT;

-- The hard coverage invariant: at most one active owner for any source point
-- in a conversation.  Rebuilds are staged, then replace the old active row in
-- one transaction.
ALTER TABLE conversation_compartments
    ADD CONSTRAINT conversation_compartments_active_range_excl
    EXCLUDE USING gist (
        conversation_id WITH =,
        source_range WITH &&
    ) WHERE (state = 'active');

CREATE UNIQUE INDEX conversation_compartments_materialization_idx
    ON conversation_compartments (conversation_id, materialization_version);

CREATE INDEX conversation_compartments_active_order_idx
    ON conversation_compartments (conversation_id, start_ingest_seq, end_ingest_seq)
    WHERE state = 'active';

CREATE TABLE compartment_evidence (
    compartment_id       bigint      NOT NULL REFERENCES conversation_compartments(id) ON DELETE RESTRICT,
    summary_tier         text        NOT NULL CHECK (summary_tier IN ('p1', 'p2', 'p3')),
    source_message_id    bigint      NOT NULL REFERENCES messages(message_id) ON DELETE RESTRICT,
    source_principal_id  bigint      NOT NULL,
    created_at           timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (compartment_id, summary_tier, source_message_id)
);

CREATE INDEX compartment_evidence_message_idx
    ON compartment_evidence (source_message_id, compartment_id);

CREATE TABLE episode_memory_proposals (
    capture_run_id          bigint      NOT NULL REFERENCES episode_capture_runs(id) ON DELETE RESTRICT,
    proposal_index          integer     NOT NULL CHECK (proposal_index >= 0),
    proposal                jsonb        NOT NULL,
    evidence_message_ids    bigint[]    NOT NULL DEFAULT '{}',
    outcome                 text        NOT NULL CHECK (
        outcome IN ('applied', 'rejected_validation', 'rejected_store')
    ),
    outcome_reason          text,
    memory_id               bigint,
    memory_version          bigint,
    created_at              timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (capture_run_id, proposal_index),
    FOREIGN KEY (memory_id, memory_version)
        REFERENCES memory_versions(memory_id, version) ON DELETE RESTRICT,
    CHECK (
        (memory_id IS NULL AND memory_version IS NULL)
        OR
        (memory_id IS NOT NULL AND memory_version IS NOT NULL)
    )
);

CREATE FUNCTION reject_episode_evidence_mutation()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION '% is append-only', TG_TABLE_NAME
        USING ERRCODE = '55000';
END;
$$;

CREATE TRIGGER compartment_evidence_append_only
BEFORE UPDATE OR DELETE ON compartment_evidence
FOR EACH ROW EXECUTE FUNCTION reject_episode_evidence_mutation();

CREATE TRIGGER episode_memory_proposals_append_only
BEFORE UPDATE OR DELETE ON episode_memory_proposals
FOR EACH ROW EXECUTE FUNCTION reject_episode_evidence_mutation();
