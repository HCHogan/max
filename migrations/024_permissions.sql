-- Dynamic command permissions (0.3): explicit per-user grants that
-- sit between the config-level owner list and the NapCat-role tier
-- in the resolution order (owner > explicit grant/deny > group
-- owner/admin role > member).
--
--   capability: a command capability name ("model", "persona",
--               "clear", …) — one row per grant.
--   scope_group_id: NULL = global grant, else the group it covers.
--   deny: TRUE turns the row into an explicit revocation that beats
--         the role tier (e.g. strip a rogue group admin of !clear).
--
-- granted_by/granted_at double as the audit trail.
CREATE TABLE permissions (
    id              bigserial   PRIMARY KEY,
    user_id         bigint      NOT NULL,
    capability      text        NOT NULL,
    scope_group_id  bigint,
    deny            boolean     NOT NULL DEFAULT false,
    granted_by      bigint      NOT NULL,
    granted_at      timestamptz NOT NULL DEFAULT now(),
    UNIQUE (user_id, capability, scope_group_id)
);

CREATE INDEX permissions_user_idx ON permissions (user_id);
