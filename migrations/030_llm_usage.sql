-- Token accounting, one row per completed LLM call.  Until now usage
-- only existed as log lines ("llm: got content" usage fields), so any
-- question about spend meant journalctl archaeology — and the journal
-- rotates.  The admin API's /api/usage reads this table.
--
--   group_id: the group the call served; NULL for groupless work
--             (sticker/media captions run against a shared library).
--   source:   which subsystem spent — 'turn' (agent round), 'wrapup'
--             (turn-cap salvage call), 'intent', 'supplement', 'memx',
--             'memx-compact', 'caption'.
--   profile:  the LLM profile name (what !model shows), not the wire
--             model id — profiles are the unit an operator reasons in.
--   cached_prompt_tokens: NULL when the gateway reported no cache
--             split (absent measurement, not a 0% hit rate).
CREATE TABLE llm_usage (
    id                    bigserial   PRIMARY KEY,
    at                    timestamptz NOT NULL DEFAULT now(),
    group_id              bigint,
    source                text        NOT NULL,
    profile               text        NOT NULL,
    prompt_tokens         int         NOT NULL,
    completion_tokens     int         NOT NULL,
    cached_prompt_tokens  int
);

CREATE INDEX llm_usage_at_idx ON llm_usage (at DESC);
CREATE INDEX llm_usage_group_at_idx ON llm_usage (group_id, at DESC);
