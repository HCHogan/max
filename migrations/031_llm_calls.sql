-- The full request and response of every LLM call, so "why did it
-- answer that" is answerable after the fact instead of being
-- reconstructed from log lines.
--
-- Deliberately a second table rather than more columns on llm_usage.
-- The two have opposite lifetimes: usage is a handful of integers you
-- want the whole history of, bodies are tens of kilobytes you want the
-- recent past of.  Splitting them lets the bodies be pruned on a
-- schedule while the spend curve stays intact forever.
--
-- Images never reach this table at full size: Max.Effects.LLM
-- redacts base64 data URLs to "data:<mime>;base64,…(N chars)" before
-- the insert.  A single multimodal turn would otherwise be megabytes,
-- and the pixels are not what you come here to read.
--
--   request:  the exact JSON body sent (post-redaction), including
--             the system prompt, the whole transcript and the tool
--             specs — the model's entire view of the world.
--   response: the parsed reply, NULL when the call failed.
--   error:    why it failed, NULL on success.  Until now a failed
--             call left nothing behind but a log line.
CREATE TABLE llm_calls (
    id                    bigserial   PRIMARY KEY,
    at                    timestamptz NOT NULL DEFAULT now(),
    group_id              bigint,
    source                text        NOT NULL,
    profile               text        NOT NULL,
    model                 text        NOT NULL,
    streamed              boolean     NOT NULL DEFAULT false,
    duration_ms           int         NOT NULL,
    request               jsonb       NOT NULL,
    response              jsonb,
    error                 text,
    prompt_tokens         int,
    completion_tokens     int,
    cached_prompt_tokens  int
);

-- The list view is "newest first, optionally one group or one source".
CREATE INDEX llm_calls_at_idx ON llm_calls (at DESC);
CREATE INDEX llm_calls_group_at_idx ON llm_calls (group_id, at DESC);
-- The pruner deletes by age; a plain btree on `at` serves it too.
