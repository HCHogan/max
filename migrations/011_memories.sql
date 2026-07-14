-- Long-term memory: one row = one remembered fact the agent (or a
-- human via !memory) chose to keep.
--
--   scope='group': keyed by group_id — facts about a group (ongoing
--                  projects, conventions, running jokes).
--   scope='user':  keyed by user_id and shared ACROSS groups — facts
--                  about a person (preferences, expertise, promises).
--                  source_group_id records where it was learned.
--
-- Deliberately no vector column: the working set per scope is capped
-- small (tool-level cap) and injected wholesale into the prompt, so
-- there is no retrieval step to accelerate.  If that ever changes,
-- pgvector can be bolted on without touching this shape.
CREATE TABLE memories (
    id              bigserial   PRIMARY KEY,
    scope           text        NOT NULL CHECK (scope IN ('group', 'user')),
    scope_id        bigint      NOT NULL,
    content         text        NOT NULL,
    source_group_id bigint,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX memories_scope_idx ON memories (scope, scope_id);
