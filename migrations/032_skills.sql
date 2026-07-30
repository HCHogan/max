-- Skills: named instruction packs the agent pulls into context on
-- demand.  The system prompt carries only a byte-stable index (name +
-- one-line description); the body enters the conversation as a
-- use_skill tool result, so it costs tokens only in dispatches that
-- actually use it.
--
--   group_id NULL   — global, visible in every group
--   group_id = <g>  — visible only in that group (shadows a global
--                     skill of the same name)
CREATE TABLE skills (
    id          bigserial   PRIMARY KEY,
    name        text        NOT NULL,
    group_id    bigint,
    description text        NOT NULL,
    body        text        NOT NULL,
    enabled     boolean     NOT NULL DEFAULT true,
    -- QQ uid that taught it from chat; NULL = minted via the admin API.
    created_by  bigint,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now()
);

-- One name per scope.  Postgres unique indexes treat NULLs as
-- distinct, so the global scope collapses to 0 (no real group id is
-- ever 0) to keep two global skills from sharing a name.
CREATE UNIQUE INDEX skills_scope_name_idx ON skills (COALESCE(group_id, 0), name);
