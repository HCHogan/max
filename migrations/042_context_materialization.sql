-- Durable prompt materialization boundary.  Historian may publish new active
-- compartments continuously, but a conversation's stable prompt prefix only
-- changes when ContextPolicy publishes one explicit revision.

CREATE TABLE context_materializations (
    conversation_id          bigint      PRIMARY KEY,
    revision                 bigint      NOT NULL CHECK (revision > 0),
    end_ingest_seq           bigint      NOT NULL CHECK (end_ingest_seq > 0),
    policy_version           text        NOT NULL CHECK (policy_version <> ''),
    source_fingerprint       text        NOT NULL CHECK (source_fingerprint ~ '^[0-9a-f]{64}$'),
    items                    jsonb       NOT NULL CHECK (jsonb_typeof(items) = 'array'),
    reason                   text        NOT NULL CHECK (
        reason IN ('initial_canary', 'high_water', 'projection_change', 'manual_rebuild')
    ),
    created_at               timestamptz NOT NULL DEFAULT now(),
    updated_at               timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE context_materialization_versions (
    conversation_id          bigint      NOT NULL,
    revision                 bigint      NOT NULL CHECK (revision > 0),
    end_ingest_seq           bigint      NOT NULL CHECK (end_ingest_seq > 0),
    policy_version           text        NOT NULL,
    source_fingerprint       text        NOT NULL CHECK (source_fingerprint ~ '^[0-9a-f]{64}$'),
    items                    jsonb       NOT NULL CHECK (jsonb_typeof(items) = 'array'),
    reason                   text        NOT NULL,
    created_at               timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (conversation_id, revision)
);

CREATE FUNCTION reject_context_materialization_version_mutation()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'context_materialization_versions is append-only'
        USING ERRCODE = '55000';
END;
$$;

CREATE TRIGGER context_materialization_versions_append_only
BEFORE UPDATE OR DELETE ON context_materialization_versions
FOR EACH ROW EXECUTE FUNCTION reject_context_materialization_version_mutation();
