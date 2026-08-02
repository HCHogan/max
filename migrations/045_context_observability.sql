-- Persist the decision trace for the prompt that was actually rendered.  The
-- trace is derived state: it contains no prompt body and can be pruned without
-- affecting messages, compartments, memories, or reconstruction.

CREATE TABLE context_plan_traces (
    id                         bigserial   PRIMARY KEY,
    conversation_id            bigint      NOT NULL,
    trigger_message_id         bigint      NOT NULL,
    history_mode               text        NOT NULL CHECK (
        history_mode IN ('legacy', 'tiered')
    ),
    policy_version             text        NOT NULL CHECK (policy_version <> ''),
    materialization_revision   bigint,
    materialization_reason     text,
    estimated_prompt_tokens    integer     NOT NULL CHECK (estimated_prompt_tokens >= 0),
    prompt_token_limit         integer     NOT NULL CHECK (prompt_token_limit > 0),
    max_input_tokens           integer     NOT NULL CHECK (max_input_tokens > 0),
    reserved_output_tokens     integer     NOT NULL CHECK (reserved_output_tokens >= 0),
    attachment_reserve         integer     NOT NULL CHECK (attachment_reserve >= 0),
    tool_round_reserve         integer     NOT NULL CHECK (tool_round_reserve >= 0),
    within_budget              boolean     NOT NULL,
    decisions                  jsonb       NOT NULL CHECK (jsonb_typeof(decisions) = 'array'),
    created_at                 timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX context_plan_traces_conversation_idx
    ON context_plan_traces (conversation_id, id DESC);
