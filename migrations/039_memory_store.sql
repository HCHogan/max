-- Turn the mutable memories table into a stable-identity current projection
-- backed by append-only versions, evidence, and mutation audit records.

ALTER TABLE memories
    ADD COLUMN version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
    ADD COLUMN lifecycle text NOT NULL DEFAULT 'active'
        CHECK (lifecycle IN ('active', 'permanent', 'archived', 'superseded')),
    ADD COLUMN category text
        CHECK (category IS NULL OR category IN (
            'person_fact', 'preference', 'group_convention',
            'ongoing_project', 'commitment', 'decision',
            'running_joke', 'relationship_context'
        )),
    ADD COLUMN superseded_by bigint REFERENCES memories(id) ON DELETE RESTRICT;

ALTER TABLE memories
    ADD CONSTRAINT memories_supersession_consistent CHECK (
        (lifecycle = 'superseded' AND superseded_by IS NOT NULL AND superseded_by <> id)
        OR
        (lifecycle <> 'superseded' AND superseded_by IS NULL)
    );

-- A group-scoped row's owning group is necessarily its origin conversation.
-- This repairs only that logically certain legacy case.  A user row whose old
-- source_group_id is NULL stays unknown rather than receiving a fabricated
-- origin.
UPDATE memories
SET source_group_id = scope_id
WHERE scope = 'group' AND source_group_id IS NULL;

CREATE TABLE memory_versions (
    memory_id       bigint      NOT NULL REFERENCES memories(id) ON DELETE RESTRICT,
    version         bigint      NOT NULL CHECK (version > 0),
    content         text        NOT NULL,
    lifecycle       text        NOT NULL
        CHECK (lifecycle IN ('active', 'permanent', 'archived', 'superseded')),
    category        text
        CHECK (category IS NULL OR category IN (
            'person_fact', 'preference', 'group_convention',
            'ongoing_project', 'commitment', 'decision',
            'running_joke', 'relationship_context'
        )),
    superseded_by   bigint      REFERENCES memories(id) ON DELETE RESTRICT,
    created_at      timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (memory_id, version)
);

CREATE TABLE memory_evidence (
    id                       bigserial   PRIMARY KEY,
    memory_id                bigint      NOT NULL,
    memory_version           bigint      NOT NULL,
    evidence_kind            text        NOT NULL
        CHECK (evidence_kind IN ('legacy', 'message', 'range', 'episode', 'maintenance', 'admin')),
    source_conversation_id   bigint,
    source_principal_id      bigint,
    source_message_id        bigint,
    source_start_ingest_seq  bigint,
    source_end_ingest_seq    bigint,
    source_episode_id        bigint,
    note                     text,
    created_at               timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (memory_id, memory_version)
        REFERENCES memory_versions(memory_id, version) ON DELETE RESTRICT,
    CHECK (
        (source_start_ingest_seq IS NULL AND source_end_ingest_seq IS NULL)
        OR
        (source_start_ingest_seq IS NOT NULL
         AND source_end_ingest_seq IS NOT NULL
         AND source_start_ingest_seq <= source_end_ingest_seq)
    ),
    CHECK (
        evidence_kind = 'legacy'
        OR (evidence_kind = 'message'
            AND source_conversation_id IS NOT NULL
            AND source_message_id IS NOT NULL)
        OR (evidence_kind = 'range'
            AND source_conversation_id IS NOT NULL
            AND source_start_ingest_seq IS NOT NULL)
        OR (evidence_kind = 'episode'
            AND source_conversation_id IS NOT NULL
            AND source_episode_id IS NOT NULL)
        OR (evidence_kind = 'maintenance'
            AND source_conversation_id IS NOT NULL)
        OR (evidence_kind = 'admin')
    )
);

CREATE TABLE memory_mutations (
    id                  bigserial   PRIMARY KEY,
    memory_id           bigint      NOT NULL,
    from_version        bigint,
    to_version          bigint      NOT NULL CHECK (to_version > 0),
    operation           text        NOT NULL
        CHECK (operation IN (
            'create', 'update', 'archive', 'make_permanent',
            'restore', 'supersede', 'backfill'
        )),
    actor_kind          text        NOT NULL CHECK (actor_kind <> ''),
    actor_principal_id  bigint,
    conversation_id     bigint,
    reason              text,
    created_at          timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (memory_id, to_version)
        REFERENCES memory_versions(memory_id, version) ON DELETE RESTRICT
);

CREATE INDEX memories_visible_namespace_idx
    ON memories (scope, scope_id, source_group_id, updated_at DESC, id DESC)
    WHERE lifecycle IN ('active', 'permanent');

CREATE INDEX memory_versions_memory_idx
    ON memory_versions (memory_id, version DESC);

CREATE INDEX memory_evidence_memory_idx
    ON memory_evidence (memory_id, memory_version);

CREATE INDEX memory_evidence_source_range_idx
    ON memory_evidence (source_conversation_id, source_start_ingest_seq, source_end_ingest_seq)
    WHERE source_start_ingest_seq IS NOT NULL;

CREATE INDEX memory_mutations_memory_idx
    ON memory_mutations (memory_id, created_at DESC, id DESC);

-- Existing rows have a stable identity but no trustworthy exact source
-- citation.  Preserve their known source_group_id and label the evidence as
-- legacy; never invent a message or episode reference.
INSERT INTO memory_versions
    (memory_id, version, content, lifecycle, category, superseded_by, created_at)
SELECT id, 1, content, lifecycle, category, superseded_by, updated_at
FROM memories;

INSERT INTO memory_evidence
    (memory_id, memory_version, evidence_kind, source_conversation_id, note, created_at)
SELECT id, 1, 'legacy', source_group_id,
       'Backfilled from the pre-versioned memories table; exact source evidence is unavailable.',
       updated_at
FROM memories;

INSERT INTO memory_mutations
    (memory_id, from_version, to_version, operation, actor_kind,
     conversation_id, reason, created_at)
SELECT id, NULL, 1, 'backfill', 'migration', source_group_id,
       'migration 039 legacy backfill', updated_at
FROM memories;

-- These ledgers are append-only.  TRUNCATE remains available to the isolated
-- test database, but ordinary UPDATE/DELETE attempts fail closed.
CREATE FUNCTION reject_memory_ledger_mutation()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION '% is append-only', TG_TABLE_NAME
        USING ERRCODE = '55000';
END;
$$;

CREATE TRIGGER memory_versions_append_only
BEFORE UPDATE OR DELETE ON memory_versions
FOR EACH ROW EXECUTE FUNCTION reject_memory_ledger_mutation();

CREATE TRIGGER memory_evidence_append_only
BEFORE UPDATE OR DELETE ON memory_evidence
FOR EACH ROW EXECUTE FUNCTION reject_memory_ledger_mutation();

CREATE TRIGGER memory_mutations_append_only
BEFORE UPDATE OR DELETE ON memory_mutations
FOR EACH ROW EXECUTE FUNCTION reject_memory_ledger_mutation();
