-- Scheduled reminders the bot delivers on its own, later.  A reminder
-- is either one-shot (cron_expr IS NULL: fires once, then fired_at is
-- stamped) or recurring (cron_expr set: after each fire, fire_at is
-- advanced to the next matching wall-clock time and the row stays
-- pending).  fire_at is always the next (or only) delivery instant,
-- stored UTC like every other timestamp; the cron expression is
-- interpreted against the configured display timezone's wall clock.
--
-- group_id may be negative — that's the private-chat pseudo-group
-- convention (OneBot.Types.isPrivateChat), so private-chat reminders
-- fall out of the same table for free.
CREATE TABLE reminders (
    id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    group_id   bigint      NOT NULL,   -- conversation to deliver into
    user_id    bigint      NOT NULL,   -- who asked; @-mentioned on fire
    self_id    bigint      NOT NULL,   -- bot account that owns it
    text       text        NOT NULL,   -- reminder body
    cron_expr  text,                   -- NULL = one-shot; set = recurring
    fire_at    timestamptz NOT NULL,   -- next delivery instant (UTC)
    created_at timestamptz NOT NULL DEFAULT now(),
    fired_at   timestamptz             -- NULL = pending; set = one-shot done
);

-- The scheduler only ever asks "what's the earliest pending reminder"
-- and "which pending reminders are due now", so a partial index over
-- just the pending rows, ordered by fire_at, serves both.
CREATE INDEX reminders_due_idx ON reminders (fire_at) WHERE fired_at IS NULL;
