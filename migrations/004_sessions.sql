-- Per-group bot session state.  Group-wide shared: anyone in the group
-- can !clear, !model X, !persona X.  Branches stored as separate rows
-- keyed by (group_id, branch); the active branch is recorded in a
-- pointer row whose `branch` is the literal '@active' sentinel.

CREATE TABLE sessions (
    group_id        bigint  NOT NULL,
    branch          text    NOT NULL,           -- branch name; 'main' is the default
    model           text,                        -- profile name from [llm.profiles.*]; NULL = default
    persona         text,                        -- NULL = inherit AppConfig.persona
    history         jsonb   NOT NULL DEFAULT '[]'::jsonb,   -- [ChatMessage]
    btw_notes       jsonb   NOT NULL DEFAULT '[]'::jsonb,   -- pending notes, [text]
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (group_id, branch)
);

-- Pointer to the active branch for each group.  Decoupled from the
-- branch rows so !switch is a single-row update, and a deleted active
-- branch can be detected and recovered.
CREATE TABLE session_active_branch (
    group_id    bigint  PRIMARY KEY,
    branch      text    NOT NULL,
    updated_at  timestamptz NOT NULL DEFAULT now()
);
