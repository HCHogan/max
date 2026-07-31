-- Per-session reasoning-effort override (!effort): NULL = follow the
-- active profile's configured effort (or send nothing).
ALTER TABLE sessions ADD COLUMN effort_override text;
